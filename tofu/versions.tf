terraform {
  required_version = ">= 1.8"

  required_providers {
    cloudflare = {
      source = "cloudflare/cloudflare"
      # The R2 custom-domain and account-token schemas used here are v5-only.
      version = "~> 5.26"
    }
  }
}

# Authenticates from $CLOUDFLARE_API_TOKEN — a human-operated bootstrap token,
# deliberately not stored in this repo. See README.md for the scopes it needs.
provider "cloudflare" {}
