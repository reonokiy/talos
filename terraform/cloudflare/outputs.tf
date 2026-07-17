output "zone" {
  description = "Non-secret Cloudflare zone selected for ExternalDNS."
  value = {
    name = local.zone_name
    id   = local.zone_id
  }
}

output "onepassword_item" {
  description = "Terraform-managed 1Password item containing the ExternalDNS credential."
  value       = onepassword_item.external_dns.id
}
