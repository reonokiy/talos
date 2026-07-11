output "bucket" {
  description = "Non-secret B2 connection settings used by fnox."
  value = {
    name           = b2_bucket.flux.bucket_name
    endpoint       = "s3.eu-central-003.backblazeb2.com"
    region         = "eu-central-003"
    current_prefix = local.current_prefix
    release_prefix = local.release_prefix
  }
}

output "onepassword_item" {
  description = "Terraform-managed 1Password item containing all generated B2 credentials."
  value       = onepassword_item.b2_credentials.id
}
