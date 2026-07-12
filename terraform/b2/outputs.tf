output "bucket" {
  description = "Non-secret B2 connection settings used by fnox."
  value = {
    name           = b2_bucket.flux.bucket_name
    endpoint       = local.endpoint
    region         = local.region
    current_prefix = local.current_prefix
    release_prefix = local.release_prefix
  }
}

output "onepassword_item" {
  description = "Terraform-managed 1Password item containing all generated B2 credentials."
  value       = onepassword_item.b2_credentials.id
}
