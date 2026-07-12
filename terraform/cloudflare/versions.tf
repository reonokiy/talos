terraform {
  required_version = ">= 1.11.0, < 2.0.0"

  # Organization and workspace are supplied by the cloudflare-terraform
  # fnox profile. Local execution keeps provider credentials off HCP workers.
  cloud {}

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "5.21.1"
    }

    onepassword = {
      source  = "1Password/onepassword"
      version = "3.3.1"
    }
  }
}
