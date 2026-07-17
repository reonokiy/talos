# B2 Terraform stack

This stack owns the private `talos-nokiy-net` bucket, the three application
keys used by the publishing, reconciliation and recovery paths, and the
`talos.nokiy.net/b2-talos-nokiy-net` 1Password item that receives those keys.
The bucket retains its existing B2-managed AES-256 server-side encryption and
File Lock setting; both are declared explicitly to prevent an imported bucket
from being replaced.

State is stored in HCP Terraform. Create a workspace named `talos-b2`, set its
execution mode to **Local**, and replace these placeholders in the root
`fnox.toml`:

```text
TF_CLOUD_ORGANIZATION=reonokiy
TF_WORKSPACE=talos-b2
TF_TOKEN_app_terraform_io=op://dev/terraform/API_TOKEN
TF_VAR_onepassword_service_account_token=op://dev/talos-terraform-onepassword-writer/credential
```

The `b2-terraform` profile injects the HCP token only into local Terraform
subprocesses. Local execution keeps the B2 and 1Password credentials on the
operator machine while HCP Terraform provides encrypted state, locking and
state history.

Terraform needs a B2 account-level key that can create buckets and application
keys. Store it in this separate 1Password item:

```text
Vault: talos.nokiy.net
Item: b2-terraform-admin
Fields: ACCESS_KEY, SECRET_KEY
```

The root `fnox.toml` exposes it only to local plan/apply subprocesses through
the `b2-terraform` profile:

```bash
mise run b2:tf:init
mise run b2:tf:plan
mise run b2:tf:apply
```

Authentication is intentionally split. fnox uses the local `op` CLI/Desktop
session to resolve the profile. The Terraform 1Password provider receives its
Service Account token only through
`TF_VAR_onepassword_service_account_token`. Do not export or define
`OP_SERVICE_ACCOUNT_TOKEN`, because fnox would then use that token while
resolving the profile.

Create the `talos-terraform-onepassword-writer` item in `dev` with a
`credential` field containing a dedicated Terraform writer Service Account
token. The Service Account needs only the read/create/edit permissions required
in `talos.nokiy.net` and must not have access to `dev`; the operator's Desktop
session resolves the token before Terraform receives it. Never reuse the
read-only ESO Service Account that is bootstrapped into the cluster.

If `b2-talos-nokiy-net` already exists, import it before the first plan so
Terraform updates it instead of creating a duplicate. Copy the vault and item
UUIDs from `op vault get` and `op item get`, then run:

```bash
terraform -chdir=terraform/b2 import \
  onepassword_item.b2_credentials \
  'vaults/<vault-uuid>/items/<item-uuid>'
```

Skip the import when the item does not exist. On apply, Terraform organizes the
item into these sections:

```text
configuration: ENDPOINT, REGION, BUCKET, CURRENT_PREFIX, RELEASES_PREFIX
publisher: ACCESS_KEY, SECRET_KEY
flux_reader: READ_ACCESS_KEY, READ_SECRET_KEY
recovery_reader: RECOVERY_ACCESS_KEY, RECOVERY_SECRET_KEY
```

Key fields are concealed. Configuration fields are ordinary strings so they
remain easy to inspect in 1Password.

If the B2 bucket already exists, look up its `bucketId` in the Backblaze console
and run the import task. It loads all configured credentials from the
`b2-terraform` fnox profile. The underlying script only prompts, with terminal
echo disabled, for a value missing from that profile and never writes secrets
to disk:

```bash
mise run b2:tf:import-manual '<b2-bucket-id>'
```

B2 only returns an application-key secret when Terraform creates it. Losing
Terraform state therefore requires rotating the affected key even though a
copy remains in 1Password.

HCP Terraform state contains all generated application-key secrets. Restrict
workspace access accordingly and do not expose state outputs in CI logs.
