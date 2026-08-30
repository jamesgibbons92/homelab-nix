# Tailscale Kubernetes operator (chosen over a
# self-hosted split-DNS resolver so each exposed service becomes its own
# tailnet node with a real MagicDNS name and an automatic HTTPS cert).
#
# Two pieces land in k3s's auto-deploy dir (/var/lib/rancher/k3s/server/
# manifests):
#   1. a sops-rendered Secret with the operator's OAuth client creds —
#      rendered at activation so the creds never enter the Nix store;
#   2. a HelmChart resource installed by k3s's bundled Helm controller.
#
# Manual prerequisites in the Tailscale admin console (see README):
#   - Access controls: tagOwners for tag:k8s-operator and tag:k8s
#   - An OAuth client (Devices + Auth Keys = write) tagged tag:k8s-operator,
#     its id/secret stored in secrets/secrets.yaml as:
#         tailscale-oauth-client-id
#         tailscale-oauth-client-secret
{config, ...}: {
  sops.secrets.tailscale-oauth-client-id = {};
  sops.secrets.tailscale-oauth-client-secret = {};

  sops.templates."tailscale-operator-oauth.yaml" = {
    # k3s applies everything in this dir; retried by the addon controller
    # if the namespace isn't there yet on the first pass.
    path = "/var/lib/rancher/k3s/server/manifests/tailscale-operator-oauth.yaml";
    content = ''
      apiVersion: v1
      kind: Namespace
      metadata:
        name: tailscale
      ---
      apiVersion: v1
      kind: Secret
      metadata:
        name: operator-oauth
        namespace: tailscale
      stringData:
        client_id: ${config.sops.placeholder.tailscale-oauth-client-id}
        client_secret: ${config.sops.placeholder.tailscale-oauth-client-secret}
    '';
  };

  services.k3s.manifests.tailscale-operator.content = {
    apiVersion = "helm.cattle.io/v1";
    kind = "HelmChart";
    metadata = {
      name = "tailscale-operator";
      namespace = "kube-system";
    };
    spec = {
      repo = "https://pkgs.tailscale.com/helmcharts";
      chart = "tailscale-operator";
      # Latest as of 2026-08-29; bump deliberately, check
      # https://pkgs.tailscale.com/helmcharts/index.yaml
      version = "1.102.3";
      targetNamespace = "tailscale";
      # oauth.* left empty on purpose: the operator picks up the
      # `operator-oauth` Secret rendered above instead of the chart
      # creating its own from values.
      valuesContent = ''
        oauth:
          clientId: ""
          clientSecret: ""
      '';
    };
  };
}
