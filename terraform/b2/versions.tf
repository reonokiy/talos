terraform {
  required_version = ">= 1.10.0, < 2.0.0"

  # Organization and workspace are supplied by the b2-terraform fnox profile.
  cloud {}

  required_providers {
    b2 = {
      source  = "Backblaze/b2"
      version = "0.13.0"
    }

    onepassword = {
      source  = "1Password/onepassword"
      version = "3.3.1"
    }
  }
}
