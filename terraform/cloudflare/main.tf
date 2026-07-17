data "cloudflare_zones" "external_dns" {
  name      = local.zone_name
  status    = "active"
  max_items = 2
}

data "cloudflare_api_token_permission_groups_list" "dns_write" {
  name      = "DNS Write"
  scope     = "com.cloudflare.api.account.zone"
  max_items = 2
}

data "cloudflare_api_token_permission_groups_list" "zone_read" {
  name      = "Zone Read"
  scope     = "com.cloudflare.api.account.zone"
  max_items = 2
}

resource "cloudflare_api_token" "external_dns" {
  name   = "talos-production-external-dns"
  status = "active"

  policies = [{
    effect = "allow"
    permission_groups = [
      {
        id = coalesce(local.dns_write_permission_id, "missing")
      },
      {
        id = coalesce(local.zone_read_permission_id, "missing")
      },
    ]
    resources = jsonencode({
      (local.zone_resource_identifier) = "*"
    })
  }]

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = local.zone_id != null
      error_message = "Expected exactly one active Cloudflare zone named nokiy.net."
    }

    precondition {
      condition     = local.dns_write_permission_id != null
      error_message = "Expected exactly one zone-scoped Cloudflare DNS Write permission group."
    }

    precondition {
      condition     = local.zone_read_permission_id != null
      error_message = "Expected exactly one zone-scoped Cloudflare Zone Read permission group."
    }
  }
}

data "onepassword_vault" "talos" {
  name = "talos.nokiy.net"
}

resource "onepassword_item" "external_dns" {
  vault    = data.onepassword_vault.talos.uuid
  title    = "external-dns"
  category = "login"
  tags     = ["terraform", "talos", "external-dns", "cloudflare"]

  section_map = {
    cloudflare = {
      field_map = {
        "api-token" = {
          type  = "CONCEALED"
          value = cloudflare_api_token.external_dns.value
        }
        "zone-id" = {
          type  = "STRING"
          value = local.zone_id
        }
      }
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}
