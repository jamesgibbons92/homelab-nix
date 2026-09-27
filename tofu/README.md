# Cloudflare resources for the niks3 binary cache

Creates the R2 bucket, its public read hostname, and the bucket-scoped R2 API
token that `modules/niks3.nix` signs uploads with. The cluster side is not
managed here — see `modules/niks3.nix` and `clusters/sanzang/niks3/`.

## Run it

`opentofu` and `awscli2` are in the devShell (`.envrc` loads it via direnv).

Create a **bootstrap** API token in the Cloudflare dashboard (My Profile → API
Tokens) with:

| Scope   | Permission                  | Why                               |
| ------- | --------------------------- | --------------------------------- |
| Account | Workers R2 Storage · Edit   | create the bucket + custom domain |
| Account | **Account API Tokens · Edit** | mint the scoped R2 token          |
| Zone    | Zone · Read                 | look up the zone by name          |
| Zone    | DNS · Edit                  | the custom domain's DNS record    |

Note the second row: **Account** API Tokens, not the similarly-named *User* API
Tokens permission. This module uses Cloudflare's account-scoped token endpoints
(`/accounts/{id}/tokens`), because the user-scoped ones reject API-token auth
outright with `9109 Valid user-level authentication not found` — a token can
never call them, no matter which permissions it has.

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in account_id and zone
export CLOUDFLARE_API_TOKEN=<bootstrap token>

tofu init
tofu plan
tofu apply
```

## Feed the output into sops

`tofu apply` prints everything `modules/niks3.nix` needs. The two credentials
are `sensitive`, so read them explicitly:

```bash
tofu output                             # s3_endpoint, bucket_name, cache_url
tofu output -raw r2_access_key_id       # -> sops key niks3-r2-access-key
tofu output -raw r2_secret_access_key   # -> sops key niks3-r2-secret-key

sops ../secrets/secrets.yaml
```

Confirm the derived key pair actually works against R2 before rebuilding —
this is the one step where a wrong assumption stays silent until niks3 starts
failing uploads:

```bash
AWS_ACCESS_KEY_ID=$(tofu output -raw r2_access_key_id) \
AWS_SECRET_ACCESS_KEY=$(tofu output -raw r2_secret_access_key) \
AWS_DEFAULT_REGION=auto \
  aws s3 ls "s3://$(tofu output -raw bucket_name)" \
    --endpoint-url "https://$(tofu output -raw s3_endpoint)"
```

R2 derives S3 credentials from an API token rather than issuing a key pair:
Access Key ID is the token's `id`, Secret Access Key is the SHA-256 of the
token's `value`
([docs](https://developers.cloudflare.com/r2/api/tokens/)). `outputs.tf` does
that hashing.

## State

State is local and **contains the R2 token value in plaintext** —
`tofu/terraform.tfstate*` is gitignored. Losing it means importing or
recreating the bucket and token rather than losing the cache, but back it up
somewhere if you'd rather not do that.

## Rotating the R2 credentials

```bash
tofu apply -replace=cloudflare_account_token.r2
```

Then put the new pair in sops and `nixos-rebuild switch`. The old token stops
working the moment it is destroyed, so niks3 will fail uploads (reads are
unaffected — they don't use credentials) until the rebuild lands.

## Deleting

`tofu destroy` removes the bucket **and everything in it**. The cache is
reproducible, but every client's next build is a full rebuild.
