variable "cloudflare_api_token" {
  description = "Bootstrap API Token used only to discover the zone and create the ExternalDNS token."
  type        = string
  sensitive   = true
}

variable "onepassword_service_account_token" {
  description = "Service Account token used only to write the generated runtime credential to 1Password."
  type        = string
  sensitive   = true
}
