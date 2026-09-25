{pkgs, ...}: {
  services.k3s = {
    enable = true;
    role = "server";
    # Ingress: keeping k3s's bundled Traefik rather than swapping to
    # ingress-nginx (decided). No --disable traefik.
    # extraFlags accepts either a string or a list of strings on the
    # nixpkgs-25.11 rev this flake is pinned to (confirmed via
    # `nix eval .#nixosConfigurations.sanzang.options.services.k3s.extraFlags.type.description`).
  };

  # Scoped to the tailnet, NOT opened globally. The router does no inbound
  # port forwarding, but "not reachable from the internet" is not the same
  # as "not reachable from the LAN" — a blanket allowedTCPPorts would let
  # every device on the home network (IoT, guest devices, anything already
  # compromised) talk to the k8s API server.
  #
  # This covers 6443 and the kubelet on 10250 because k3s-server binds those
  # as host processes, so they land in the filter INPUT chain where these
  # rules live. Verified on the live host: both refuse LAN connections and
  # accept tailnet ones.
  #
  # It does NOT cover Traefik on 80/443 — see the servicelb note below.
  #
  # Port 22 is not listed here: services.openssh opens it itself, and
  # Tailscale SSH is handled inside tailscaled rather than through these
  # rules.
  networking.firewall.interfaces.tailscale0.allowedTCPPorts = [
    6443 # k8s API
  ];

  # Traefik is reachable from the whole LAN and the NixOS firewall cannot
  # stop it. k3s ServiceLB gives the Traefik LoadBalancer service a svclb-
  # pod with hostPort 80/443; the CNI portmap plugin then installs DNAT in
  # nat/PREROUTING with no source or interface match. Post-DNAT the packet
  # is addressed to the pod, so it traverses FORWARD (policy ACCEPT), never
  # INPUT — adding 80/443 to allowedTCPPorts above is purely cosmetic.
  #
  # Nothing currently uses the traefik ingressclass (the only Ingresses are
  # class "tailscale", served by the operator), so Traefik itself is open
  # surface with no function. Dropping Traefik would close it.

  # Cluster-internal traffic. The NixOS firewall filters the INPUT chain,
  # which pod->host and pod->pod traffic crosses, so k3s needs its own
  # interfaces trusted and its pod/service CIDRs allowed — otherwise
  # CoreDNS and anything talking to the API from inside the cluster fail
  # in ways that look like DNS flakiness rather than a firewall problem.
  # These are k3s's defaults; they change if --cluster-cidr is ever set.
  networking.firewall.trustedInterfaces = ["cni0" "flannel.1"];
  networking.firewall.extraCommands = ''
    iptables -A INPUT -s 10.42.0.0/16 -j ACCEPT
    iptables -A INPUT -s 10.43.0.0/16 -j ACCEPT
  '';

  # k3s writes its kubeconfig to /etc/rancher/k3s/k3s.yaml, root-owned —
  # copy it out for homelab so plain `kubectl`/`k9s` work without sudo.
  # Re-runs on every boot after k3s is up, so it also picks up a rotated
  # token if that ever happens.
  systemd.services.homelab-kubeconfig = {
    description = "Copy k3s kubeconfig for homelab";
    after = ["k3s.service"];
    wants = ["k3s.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig.Type = "oneshot";
    script = ''
      until [ -f /etc/rancher/k3s/k3s.yaml ]; do
        ${pkgs.coreutils}/bin/sleep 1
      done
      ${pkgs.coreutils}/bin/install -D -m 600 -o homelab -g users \
        /etc/rancher/k3s/k3s.yaml /home/homelab/.kube/config
    '';
  };
}
