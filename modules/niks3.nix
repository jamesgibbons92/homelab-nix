# niks3 — S3-backed Nix binary cache with reference-tracking GC.
# https://github.com/Mic92/niks3
#
# Writes go over the tailnet (clusters/sanzang/niks3/ingress.yaml), reads come
# straight from a public R2 bucket via Cloudflare's CDN, GC runs in-cluster. See
# README.md "Binary cache" for the shape and why the read path is public.
#
# Postgres is NOT here: modules/cloudnative-pg.nix installs the operator,
# clusters/sanzang/niks3/postgres-cluster.yaml declares the database. CNPG
# publishes the connection string as Secret `niks3-pg-app` (key `uri`).
#
# secrets/secrets.yaml keys, and where each comes from:
#
#   niks3-api-token        openssl rand -base64 32   (>= 36 chars)
#   niks3-signing-key      nix key generate-secret --key-name <cache-host>-1
#   niks3-r2-access-key    cd tofu && tofu output -raw r2_access_key_id
#   niks3-r2-secret-key    cd tofu && tofu output -raw r2_secret_access_key
#   niks3-s3-endpoint      tofu output -raw s3_endpoint
#   niks3-s3-bucket        tofu output -raw bucket_name
#   niks3-cache-url        tofu output -raw cache_url
#   niks3-server-url       https://niks3.<tailnet>.ts.net — the write Ingress,
#                          and the OIDC audience; no trailing slash
#   niks3-github-repo      owner/repo allowed to push, e.g. myorg/nixos-config
{config, ...}: {
  sops.secrets.niks3-api-token = {};
  sops.secrets.niks3-signing-key = {};
  sops.secrets.niks3-r2-access-key = {};
  sops.secrets.niks3-r2-secret-key = {};
  sops.secrets.niks3-s3-endpoint = {};
  sops.secrets.niks3-s3-bucket = {};
  sops.secrets.niks3-cache-url = {};
  sops.secrets.niks3-server-url = {};
  sops.secrets.niks3-github-repo = {};

  sops.templates."niks3.yaml" = {
    path = "/var/lib/rancher/k3s/server/manifests/niks3.yaml";

    # Secret keys below are fixed by the chart's mount paths — renaming one
    # silently breaks startup. The HelmChart's metadata.name must stay "niks3"
    # too: that is what names the Service the GC CronJob and ingress.yaml target.
    content = ''
      apiVersion: v1
      kind: Namespace
      metadata:
        name: niks3
      ---
      apiVersion: v1
      kind: Secret
      metadata:
        name: niks3-token
        namespace: niks3
      stringData:
        token: ${config.sops.placeholder.niks3-api-token}
      ---
      apiVersion: v1
      kind: Secret
      metadata:
        name: niks3-signing
        namespace: niks3
      stringData:
        signing-key: ${config.sops.placeholder.niks3-signing-key}
      ---
      apiVersion: v1
      kind: Secret
      metadata:
        name: niks3-s3
        namespace: niks3
      stringData:
        access-key: ${config.sops.placeholder.niks3-r2-access-key}
        secret-key: ${config.sops.placeholder.niks3-r2-secret-key}
      ---
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: niks3
        namespace: kube-system
      spec:
        chart: oci://ghcr.io/mic92/charts/niks3
        # Bump deliberately: helm show chart oci://ghcr.io/mic92/charts/niks3
        version: "1.13.0"
        targetNamespace: niks3
        valuesContent: |
          database:
            # Created by the CNPG Cluster, not by sops. Until `kubectl apply -f
            # clusters/sanzang/niks3/` lands the pod sits in
            # CreateContainerConfigError — self-healing, not a misconfiguration.
            existingSecret: niks3-pg-app

          s3:
            endpoint: ${config.sops.placeholder.niks3-s3-endpoint}
            bucket: ${config.sops.placeholder.niks3-s3-bucket}
            # R2 requires the SigV4 signing region to be "auto", and serves
            # path-style.
            region: auto
            useSSL: true
            bucketLookup: path
            existingSecret: niks3-s3

          auth:
            # Still required even though CI uses OIDC: the GC CronJob uses it.
            existingSecret: niks3-token
            oidcProviders:
              # Passed through verbatim to the server's JSON config, so these
              # keys are snake_case — NOT the camelCase of niks3's NixOS module.
              # Wrong case yields a provider matching nothing and CI 401s.
              github:
                issuer: https://token.actions.githubusercontent.com
                # Must equal the write URL exactly, no trailing slash.
                audience: ${config.sops.placeholder.niks3-server-url}
                bound_claims:
                  repository: ["${config.sops.placeholder.niks3-github-repo}"]
                  # repository alone would let any branch, tag or
                  # pull_request_target run in that repo mint a token niks3
                  # then signs NARs with.
                  ref: ["refs/heads/main"]
                scopes: [write]

          signing:
            existingSecret: niks3-signing
            # Must be non-empty whenever existingSecret is set, or the chart
            # quietly serves unsigned narinfos.
            keys: [signing-key]

          # Advertised as the substituter via /api/cache-config, so CI learns
          # both URLs from the server rather than hardcoding them.
          cacheURL: ${config.sops.placeholder.niks3-cache-url}

          # ingress.yaml instead: the chart always emits rules with a host, while
          # the Tailscale operator pattern proven here is defaultBackend plus a
          # bare hostname in tls.hosts.
          ingress:
            enabled: false
    '';
  };
}
