variable "onepassword_service_account_token" {
  description = "Dedicated local Terraform writer Service Account token used only by the 1Password provider."
  type        = string
  sensitive   = true
}
