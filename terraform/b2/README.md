# B2 Terraform stack

This stack owns the private `talos-nokiy-net` bucket, the three application
keys used by the publishing, reconciliation and recovery paths, and the
`talos.nokiy.net/b2-talos-nokiy-net` 1Password item that receives those keys.

State is stored in HCP Terraform. Create a workspace named `talos-b2`, set its
execution mode to **Local**, and replace these placeholders in the root
`fnox.toml`:

```text
TF_CLOUD_ORGANIZATION=CHANGE_ME_TF_CLOUD_ORGANIZATION
TF_WORKSPACE=talos-b2
TF_TOKEN_app_terraform_io=op://CHANGE_ME_VAULT/CHANGE_ME_ITEM/CHANGE_ME_FIELD
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

The 1Password provider uses the local `op` CLI and Desktop App integration. It
does not use a service account. The root `fnox.toml` resolves `OP_ACCOUNT` from
1Password; an exported value can override it when needed:

```bash
mise exec -- op account list
export OP_ACCOUNT='<URL or USER ID from op account list>'
mise exec -- op account get --account "$OP_ACCOUNT"
```

If `b2-talos-nokiy-net` already exists, import it before the first plan so
Terraform updates it instead of creating a duplicate. Copy the vault and item
UUIDs from `op vault get` and `op item get`, then run:

```bash
terraform -chdir=terraform/b2 import \
  onepassword_item.b2_credentials \
  'vaults/<vault-uuid>/items/<item-uuid>'
```

Skip the import when the item does not exist. On apply, Terraform writes these
concealed fields directly through the Desktop App session:

```text
ACCESS_KEY
SECRET_KEY
READ_ACCESS_KEY
READ_SECRET_KEY
RECOVERY_ACCESS_KEY
RECOVERY_SECRET_KEY
```

B2 only returns an application-key secret when Terraform creates it. Losing
Terraform state therefore requires rotating the affected key even though a
copy remains in 1Password.

HCP Terraform state contains all generated application-key secrets. Restrict
workspace access accordingly and do not expose state outputs in CI logs.
