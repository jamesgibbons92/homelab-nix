output "s3_endpoint" {
  description = "sops key niks3-s3-endpoint."
  value       = "${var.account_id}.r2.cloudflarestorage.com"
}

output "bucket_name" {
  description = "sops key niks3-s3-bucket."
  value       = cloudflare_r2_bucket.cache.name
}

output "cache_url" {
  description = "sops key niks3-cache-url, and the substituter clients use."
  value       = "https://${local.cache_hostname}"
}

# R2 does not hand out S3 key pairs: the Access Key ID is the API token's id and
# the Secret Access Key is the SHA-256 of its value.
# https://developers.cloudflare.com/r2/api/tokens/
output "r2_access_key_id" {
  description = "sops key niks3-r2-access-key."
  value       = cloudflare_account_token.r2.id
  sensitive   = true
}

output "r2_secret_access_key" {
  description = "sops key niks3-r2-secret-key."
  value       = sha256(cloudflare_account_token.r2.value)
  sensitive   = true
}

output "custom_domain_status" {
  description = "Ownership and SSL state of the cache hostname; both go active a minute or two after apply."
  value       = cloudflare_r2_custom_domain.cache.status
}
