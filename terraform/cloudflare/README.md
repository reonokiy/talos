# Cloudflare ExternalDNS Terraform stack

This independent root module creates the zone-scoped Cloudflare API Token used
by ExternalDNS and stores it with the zone ID in the
`talos.nokiy.net/external-dns/cloudflare` 1Password item. It does not manage the
zone or DNS records; ExternalDNS owns only its TXT-registered records.

State is stored in a dedicated HCP Terraform workspace named
`talos-cloudflare` with execution mode **Local**. The state contains the
generated API Token, so restrict workspace access and never inspect or export
state or sensitive plan data.

## Bootstrap credentials

Creating a scoped API Token requires one pre-existing Cloudflare management
Token. Create it manually with API Tokens Read/Write and permission to read the
active `nokiy.net` zone, then store it outside the cluster-readable vault:

```text
Vault: dev
Item: cloudflare-terraform-admin
Field: API_TOKEN
```

The Terraform 1Password provider uses the existing Service Account credential
from `talos.nokiy.net/service-account/credential`. It needs write access to the
`talos.nokiy.net` vault. fnox injects both credentials only into the local
Terraform subprocess; do not export them into an interactive shell.

## Apply

```bash
mise run cloudflare:tf:init
mise run cloudflare:tf:plan
mise run cloudflare:tf:apply
```

The generated Cloudflare Token has only zone-scoped `DNS Write` and `Zone Read`
permissions for `nokiy.net`. Terraform writes these exact 1Password fields:

```text
Item: external-dns/cloudflare
Fields: api-token, zone-id
```

That matches the ExternalSecret references under
`clusters/production/infrastructure/system/external-dns`.
Both the Token and 1Password item have Terraform destruction protection;
rotation or retirement requires a reviewed change that deliberately removes
that guard.

If the target 1Password item already exists, import it before the first plan:

```bash
fnox --no-daemon --profile cloudflare-terraform exec --no-defaults -- \
  terraform -chdir=terraform/cloudflare import \
  onepassword_item.external_dns \
  'vaults/<vault-uuid>/items/<item-uuid>'
```

If an existing ExternalDNS API Token should be adopted instead of rotated,
import its token ID as `cloudflare_api_token.external_dns` before apply. The
Cloudflare API returns the Token value only at creation, so an imported Token
cannot populate the 1Password credential; rotate it through Terraform when the
value is not already present in Terraform state.
