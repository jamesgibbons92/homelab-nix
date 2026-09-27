# Cloudflare side of the niks3 binary cache: the R2 bucket, its public read
# hostname, and a bucket-scoped R2 token for uploads and GC deletes. Cluster
# side is modules/niks3.nix.

data "cloudflare_zone" "cache" {
  filter = {
    name = var.zone
  }
}

# Must be the *account*-scoped data source: the unscoped one hits /user/tokens/...,
# which rejects API-token auth with "9109 Valid user-level authentication not
# found". No server-side name filter either — the provider URL-encodes the value
# itself, so a pre-encoded one (as the docs suggest) double-encodes and matches
# nothing. Filtered in locals instead.
data "cloudflare_account_api_token_permission_groups_list" "all" {
  account_id = var.account_id

  lifecycle {
    postcondition {
      condition = length([
        for pg in self.result : pg if pg.name == local.r2_write_permission_name
      ]) == 1
      error_message = "Expected exactly one '${local.r2_write_permission_name}' permission group in account ${var.account_id}. Has Cloudflare renamed it?"
    }
  }
}

locals {
  cache_hostname = "${var.cache_subdomain}.${var.zone}"

  # Must be the *Bucket Item* group: plain "Workers R2 Storage Write" is an
  # account-resource group, and pairing it with the bucket-scoped `resources`
  # key below either fails the create or grants account-wide R2 access.
  r2_write_permission_name = "Workers R2 Storage Bucket Item Write"

  r2_write_permission_id = one([
    for pg in data.cloudflare_account_api_token_permission_groups_list.all.result :
    pg.id if pg.name == local.r2_write_permission_name
  ])
}

resource "cloudflare_r2_bucket" "cache" {
  account_id    = var.account_id
  name          = var.bucket_name
  location      = var.location
  storage_class = "Standard"
}

# Makes the bucket publicly readable at https://<cache_hostname>/, behind
# Cloudflare's cache. This is what Nix clients use as their substituter.
resource "cloudflare_r2_custom_domain" "cache" {
  account_id  = var.account_id
  bucket_name = cloudflare_r2_bucket.cache.name
  zone_id     = data.cloudflare_zone.cache.id
  domain      = local.cache_hostname
  enabled     = true
  min_tls     = "1.2"
}

# cloudflare_account_token, not cloudflare_api_token: the latter POSTs to
# /user/tokens and rejects API-token auth the same way as above.
resource "cloudflare_account_token" "r2" {
  account_id = var.account_id
  name       = var.token_name

  policies = [{
    effect = "allow"

    permission_groups = [{
      id = local.r2_write_permission_id
    }]

    # Jurisdiction segment is "default" for a bucket created without one.
    # https://developers.cloudflare.com/r2/api/tokens/
    resources = jsonencode({
      "com.cloudflare.edge.r2.bucket.${var.account_id}_default_${cloudflare_r2_bucket.cache.name}" = "*"
    })
  }]
}
