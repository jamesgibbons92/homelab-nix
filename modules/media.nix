# Namespace and secrets for the media stack (clusters/sanzang/{qtorrent,
# radarr,jackett,jellyfin,storage}). Same pattern as tailscale-operator.nix:
# a sops-rendered manifest lands in k3s's auto-deploy dir at activation, so a
# fresh rebuild has the namespace and the VPN key in place before anyone runs
# `kubectl apply -f clusters/sanzang/...`. The workload manifests themselves
# stay plain kubectl-applied YAML.
#
# Careful: k3s's addon controller owns what it deploys. Removing this module
# (or the rendered file) deletes the Namespace — and with it every workload
# and PVC binding in it. Rename the secret, don't drop the namespace.
#
# surfshark-wireguard-private-key in secrets/secrets.yaml is the PrivateKey
# field of a Surfshark WireGuard config (the matching Address is hardcoded as
# WIREGUARD_ADDRESSES in qtorrent/deployment.yaml).
{config, ...}: {
  sops.secrets.surfshark-wireguard-private-key = {};

  sops.templates."media.yaml" = {
    path = "/var/lib/rancher/k3s/server/manifests/media.yaml";
    content = ''
      apiVersion: v1
      kind: Namespace
      metadata:
        name: media
      ---
      apiVersion: v1
      kind: Secret
      metadata:
        name: surfshark-secret
        namespace: media
      stringData:
        WIREGUARD_PRIVATE_KEY: ${config.sops.placeholder.surfshark-wireguard-private-key}
    '';
  };
}
