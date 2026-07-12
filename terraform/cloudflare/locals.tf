locals {
  zone_name = "nokiy.net"

  zone_id                  = try(one(data.cloudflare_zones.external_dns.result).id, null)
  dns_write_permission_id  = try(one(data.cloudflare_api_token_permission_groups_list.dns_write.result).id, null)
  zone_read_permission_id  = try(one(data.cloudflare_api_token_permission_groups_list.zone_read.result).id, null)
  zone_resource_identifier = local.zone_id == null ? "missing" : "com.cloudflare.api.account.zone.${local.zone_id}"
}
