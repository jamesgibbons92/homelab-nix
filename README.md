# homelab-nix

Single-node [k3s](https://k3s.io) cluster running NixOS, managed
declaratively as a flake.

Provisioned with [nixos-anywhere](https://github.com/nix-community/nixos-anywhere)
and [disko](https://github.com/nix-community/disko). Secrets are committed
encrypted via [sops-nix](https://github.com/Mic92/sops-nix). Services are
reachable over [Tailscale](https://tailscale.com) — nothing is exposed to the
internet and the router forwards no ports. Jellyfin is the one deliberate
exception, also published on the LAN (see "LAN exposure" below). The host
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
},
```

```jsonc
"acls": [
  { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:homelab:22,6443"] },
  { "action": "accept", "src": ["autogroup:member"], "dst": ["tag:k8s:443"] },
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

Then generate two credentials:

- An **OAuth client** (Settings → OAuth clients) with **Devices: write** and
  **Auth Keys: write**, tagged `tag:k8s-operator`.
- An **auth key** for the host, tagged `tag:homelab`.

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
