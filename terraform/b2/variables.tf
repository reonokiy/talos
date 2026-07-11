variable "onepassword_service_account_token" {
  description = "Service Account token used only by the Terraform 1Password provider."
  type        = string
  sensitive   = true
}
