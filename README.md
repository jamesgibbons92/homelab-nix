# homelab-nix

Single-node [k3s](https://k3s.io) cluster running NixOS, managed
declaratively as a flake.

Provisioned with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
and [disko](https://github.com/nix-community/disko). Secrets are committed
encrypted via [sops-nix](https://github.com/Mic92/sops-nix). Services are
reachable over [Tailscale](https://tailscale.com) — nothing is exposed to the
internet and the router forwards no ports. There are two deliberate exceptions:
Jellyfin is also published on the LAN (see "LAN exposure"), and the binary
cache's R2 bucket is public on the internet (see "Binary cache"). The host
rebuilds itself hourly by pulling this repo from GitHub.

Kubernetes manifests are deliberately not templated through Nix — the host
layer and the workload layer stay separate.

## Setup

### 1. Tailscale

In the ACL policy file, declare the tags:

```jsonc
"tagOwners": {
  "tag:k8s-operator": [],
  "tag:k8s":          ["tag:k8s-operator"],
  "tag:homelab":      ["autogroup:admin"],
  "tag:ci":           ["autogroup:admin"],
},
```

`tag:ci` is for GitHub Actions runners, which join the tailnet to push to the
binary cache (see "Binary cache").

```jsonc
"acls": [
  { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:homelab:22,6443"] },
  { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:k8s:443"] },
  { "action": "accept", "src": ["tag:ci"],           "dst": ["tag:k8s:443"] },
],

"ssh": [
  {
    "action": "check",           // browser re-auth, ~12h
    "src":    ["autogroup:member"],
    "dst":    ["tag:homelab"],
    "users":  ["homelab"],
  },
],
```

Then generate three credentials:

- An **OAuth client** (Settings → OAuth clients) with **Devices: write** and
  **Auth Keys: write**, tagged `tag:k8s-operator`.
- An **auth key** for the host, tagged `tag:homelab`.
- A second **OAuth client** with **Auth Keys: write**, tagged `tag:ci`. This one
  is not stored here — it goes in the build repo's GitHub secrets, where
  `tailscale/github-action` uses it to mint an ephemeral node per job.

### 2. Install

The stock nixos-anywhere kexec image is wired-DHCP only. This flake builds a
wifi-capable variant for targets without ethernet.

```bash
# Confirm the disk device on the target and fix hosts/sanzang/disko.nix
lsblk

# Build the wifi kexec installer
nix build .#kexec-installer && ls -R result/

# Boot the target into it, then join wifi
iwctl --passphrase '<psk>' station wlan0 connect '<ssid>'

# Install. DESTRUCTIVE — disko wipes the disk.
nix run github:nix-community/nixos-anywhere -- \
  --flake .#sanzang --kexec <path-to-tarball-under-./result> root@<target-ip>
```

`nixos-rebuild` does not run disko, so only re-running nixos-anywhere
repartitions.

### 3. Secrets

sops-nix decrypts with the host's **own SSH host key**, so there's no separate
key to provision or rotate on the machine. That key only exists after the
install above, so secrets are populated on the second pass.

Convert the host key to an age recipient, add it to `.sops.yaml`, then rekey:

```bash
ssh homelab@<target-ip> cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age
sops updatekeys secrets/secrets.yaml
```

Edit secrets:

```bash
sops secrets/secrets.yaml
```

Rebuild to apply secrets:

```bash
nixos-rebuild switch --flake .#sanzang --target-host homelab@<target-ip> --sudo
```

## Deploying changes

`modules/auto-upgrade.nix` has the host fetch this repo from GitHub hourly and
`nixos-rebuild switch`. Outbound HTTPS only — no inbound ports, no deploy keys
in CI, nothing for the router to forward. The tradeoff is polling latency
instead of deploy-on-push.

## Adding a service

Manifests go in `clusters/sanzang/<name>/` and are applied with `kubectl apply
-f`.

Namespaces and Secrets those manifests depend on are _not_ in `clusters/` —
they're sops-rendered into k3s's auto-deploy dir by a Nix module so a fresh
rebuild has them before anything is applied (see `modules/media.nix` for the
`media` namespace and the Surfshark WireGuard key;
`modules/tailscale-operator.nix` for the operator's OAuth creds). To add one:
put the value in
`secrets/secrets.yaml`, declare it with `sops.secrets.<name>`, and reference
`config.sops.placeholder.<name>` from a `sops.templates` manifest.

Give it an `Ingress` with `ingressClassName: tailscale`. The operator creates a
dedicated tailnet node for it, registers MagicDNS, and provisions a TLS cert —
no port forwarding, no cert-manager, no public exposure. `tls.hosts[0]` is a
bare hostname, not an FQDN; the operator appends the tailnet domain. Proxy
node state (including the WireGuard node key) is persisted by the operator to
a Secret in the `tailscale` namespace, so identity and MagicDNS survive pod
restarts.

If Tailnet Lock is enabled, a newly created proxy node shows up locked out
and won't have connectivity until it's signed:

```bash
tailscale lock status  # lists any locked-out nodes and their nodekey
tailscale lock sign nodekey:<key>
```

Storage uses k3s's local-path provisioner. Volumes are node-pinned, so
`replicas` must stay at 1; a second node is the trigger for a real CSI driver.

The binary cache doesn't follow this shape — it's installed from a Helm chart
rather than hand-written manifests, and its read path is public. See "Binary
cache" below before copying it as a pattern.

## Binary cache

[niks3](https://github.com/Mic92/niks3) serves a Nix binary cache backed by
Cloudflare R2. Three paths, deliberately separate:

```
write  GitHub runner --tailscale up--> tailnet --> niks3 Ingress
       --presigned PUT--> R2, refs tracked in Postgres
read   nix client --> Cloudflare CDN --> R2 bucket   (never touches sanzang)
GC     CronJob in-cluster --> http://niks3:80 --> R2 deletes
```

niks3 itself only signs uploads and garbage-collects; it is never in the read
path. That's what makes it cheap to run on one node.

**The R2 bucket is public.** `cache.<zone>` is a Cloudflare custom domain on the
bucket, so anyone who knows the hostname can read the cache. This is the second
deliberate exception to the tailnet-only posture, and the reason R2 is worth
using: zero egress fees and a CDN, with no inbound anything on this host. NARs
are signed with an Ed25519 key, so a public bucket leaks *what* has been built,
not the ability to poison it. Don't push closures whose store path names are
themselves sensitive.

Writes stay tailnet-only at `https://niks3.<tailnet>.ts.net`
(`clusters/sanzang/niks3/ingress.yaml`). GitHub Actions reaches it by joining the
tailnet under `tag:ci`, not by anything being exposed — and authenticates with
GitHub OIDC bound to one repository and its default branch, so there is no
niks3 token in CI.

Layout:

| Where | What |
| --- | --- |
| `tofu/` | OpenTofu: the R2 bucket, `cache.<zone>`, and a bucket-scoped R2 token |
| `modules/cloudnative-pg.nix` | CloudNativePG operator (Postgres for niks3) |
| `modules/niks3.nix` | namespace + sops secrets + the niks3 HelmChart |
| `clusters/sanzang/niks3/` | the Postgres `Cluster` and the Tailscale Ingress |

### Bringing it up

```bash
cd tofu && tofu init && tofu apply          # see tofu/README.md first
```

Generate the two secrets niks3 doesn't get from `tofu` — the API token is still
needed even though CI uses OIDC, because the GC CronJob authenticates with it:

```bash
openssl rand -base64 32                             # >= 36 chars
nix key generate-secret --key-name cache.<zone>-1
```

`modules/niks3.nix` declares **nine** sops secrets and its header comment lists
where each value comes from — the two above, five `tofu` outputs, and two
strings you pick. All nine have to exist or `nixos-rebuild` fails in
`sops-install-secrets`:

```bash
sops secrets/secrets.yaml
```

Postgres credentials are *not* among them — CNPG generates them and owns the
`niks3-pg-app` Secret.

Then rebuild and apply the workload layer:

```bash
nixos-rebuild switch --flake .#sanzang --target-host homelab@<target-ip> --sudo
kubectl apply -f clusters/sanzang/niks3/
```

Until that `kubectl apply` lands, the niks3 pod sits in
`CreateContainerConfigError` waiting on the `niks3-pg-app` Secret. That's
expected and self-healing, not a misconfiguration.

### Checking it

```bash
curl -sS https://cache.<zone>/nix-cache-info    # StoreDir, WantMassQuery, Priority: 30
curl -sS https://niks3.<tailnet>.ts.net/healthz

# The check that catches OIDC mistakes before a workflow run: an empty
# oidc_audience means the provider config didn't parse and CI will 401.
curl -sS 'https://niks3.<tailnet>.ts.net/api/cache-config?issuer=https://token.actions.githubusercontent.com' | jq
```

GC runs daily at 03:00 on closures older than 30 days. To run it now:

```bash
kubectl -n niks3 create job --from=cronjob/niks3-gc gc-manual
kubectl -n niks3 logs job/gc-manual
```

### Using it from GitHub Actions

Builds live in a separate repo. It needs `TS_OAUTH_CLIENT_ID` and
`TS_OAUTH_SECRET` from the `tag:ci` OAuth client, and:

```yaml
permissions:
  contents: read
  id-token: write          # required for niks3's OIDC auth

steps:
  - uses: actions/checkout@v5
  - uses: tailscale/github-action@v4
    with:
      oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
      oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
      tags: tag:ci
      ping: niks3          # fail fast if the tailnet route is wrong
  - uses: NixOS/nix-installer-action@main
  - uses: Mic92/niks3-action@v1
    with:
      server-url: https://niks3.<tailnet>.ts.net
  - run: nix build .#...
```

The substituter URL and trusted public key are not hardcoded: `niks3-action`
reads them from `/api/cache-config`, so runners pull from the CDN and push over
the tailnet. Because it registers a `post-build-hook`, intermediate derivations
are cached even when a build later fails or is cancelled.

Which OIDC tokens are accepted is pinned in `modules/niks3.nix` under
`auth.oidcProviders.github.bound_claims`: `repository` names the build repo, and
`ref` pins it to `refs/heads/main`. Both have to match, so a run on a feature
branch, a tag, or a `pull_request_target` gets 401 rather than a token niks3
would sign NARs with. A second build repo — or pushing from a branch other than
`main` — needs adding there and a rebuild.

For machines outside CI:

```nix
nix.settings = {
  substituters = ["https://cache.<zone>"];
  trusted-public-keys = ["cache.<zone>-1:<pubkey>"];   # nix key convert-secret-to-public
};
```

## LAN exposure

Default posture is tailnet-only, and new services should stay that way.
Jellyfin is the single exception: in order for LAN devices to stream, so
`clusters/sanzang/jellyfin/service.yaml` is `type: LoadBalancer` and k3s
ServiceLB binds port 8096 on the host. Point the client at:

```
http://192.168.0.21:8096
```

The Tailscale Ingress still works alongside it — the ClusterIP is unchanged,
so off-LAN clients keep using `https://jellyfin.<tailnet>.ts.net`.

Things to know before copying this pattern:

- **The NixOS firewall cannot scope it.** ServiceLB DNATs in nat/PREROUTING
  with no source match, so the packet crosses FORWARD, not INPUT — see the
  long note in `modules/k3s.nix`. The port is open to every device on
  192.168.0.0/24, not just the Fire TV stick. Jellyfin's own login is the
  only access control in front of the media library.
- **Don't remove ServiceLB.** `modules/k3s.nix` notes that dropping servicelb
  would close the unused Traefik surface; doing that now also takes Jellyfin
  off the LAN.
- **No auto-discovery.** The Jellyfin app finds servers by UDP broadcast on
  7359, which doesn't cross the CNI boundary. Enter the URL above by hand.
- **It's HTTP, not HTTPS.** Plaintext on the local segment only; nothing is
  routable from outside.
- `network-policies/media-deny-lan-egress.yaml` still applies. It blocks
  pod-initiated egress to the LAN; replies to inbound LAN connections are
  part of an established flow and are unaffected (verified against the live
  cluster).
