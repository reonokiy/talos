resource "b2_bucket" "flux" {
  bucket_name = local.bucket_name
  bucket_type = "allPrivate"

  bucket_info = {
    cluster    = "production"
    managed_by = "terraform"
    purpose    = "flux-source"
  }

  lifecycle_rules {
    file_name_prefix                                       = local.writer_prefix
    days_from_starting_to_canceling_unfinished_large_files = 1
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "b2_application_key" "writer" {
  key_name     = "talos-production-publisher"
  capabilities = ["writeFiles"]
  bucket_ids   = [b2_bucket.flux.bucket_id]
  name_prefix  = local.writer_prefix
}

resource "b2_application_key" "flux_reader" {
  key_name = "talos-production-flux-reader"
  capabilities = [
    "listBuckets",
    "listFiles",
    "readFiles",
  ]
  bucket_ids  = [b2_bucket.flux.bucket_id]
  name_prefix = local.current_prefix
}

resource "b2_application_key" "recovery_reader" {
  key_name     = "talos-production-recovery-reader"
  capabilities = ["readFiles"]
  bucket_ids   = [b2_bucket.flux.bucket_id]
  name_prefix  = local.release_prefix
}

data "onepassword_vault" "talos" {
  name = "talos.nokiy.net"
}

resource "onepassword_item" "b2_credentials" {
  vault    = data.onepassword_vault.talos.uuid
  title    = "b2-talos-nokiy-net"
  category = "login"
  tags     = ["terraform", "talos", "backblaze-b2"]

  section_map = {
    credentials = {
      field_map = {
        ACCESS_KEY = {
          type  = "CONCEALED"
          value = b2_application_key.writer.application_key_id
        }
        SECRET_KEY = {
          type  = "CONCEALED"
          value = b2_application_key.writer.application_key
        }
        READ_ACCESS_KEY = {
          type  = "CONCEALED"
          value = b2_application_key.flux_reader.application_key_id
        }
        READ_SECRET_KEY = {
          type  = "CONCEALED"
          value = b2_application_key.flux_reader.application_key
        }
        RECOVERY_ACCESS_KEY = {
          type  = "CONCEALED"
          value = b2_application_key.recovery_reader.application_key_id
        }
        RECOVERY_SECRET_KEY = {
          type  = "CONCEALED"
          value = b2_application_key.recovery_reader.application_key
        }
      }
    }
  }
}
