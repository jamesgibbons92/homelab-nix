variable "account_id" {
  description = "Cloudflare account ID. Also forms the R2 S3 endpoint hostname."
  type        = string
}

variable "zone" {
  description = "Zone already on Cloudflare that the cache hostname lives under, e.g. example.com."
  type        = string
}

variable "cache_subdomain" {
  description = "Label prefixed to `zone` to form the public read hostname for the bucket."
  type        = string
  default     = "cache"
}

variable "bucket_name" {
  description = "R2 bucket holding the binary cache."
  type        = string
  default     = "nix-cache"
}

variable "location" {
  description = "R2 location hint. Best-effort, and only honoured when the bucket is first created."
  type        = string
  default     = "weur"

  validation {
    condition     = contains(["apac", "eeur", "enam", "weur", "wnam", "oc"], var.location)
    error_message = "location must be one of apac, eeur, enam, weur, wnam, oc."
  }
}

variable "token_name" {
  description = "Name of the R2 API token niks3 authenticates to S3 with."
  type        = string
  default     = "niks3-r2"
}
