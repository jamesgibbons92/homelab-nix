{
  config,
  pkgs,
  ...
}: {
  nix.settings = {
    experimental-features = ["nix-command" "flakes"];
    trusted-users = ["root" "homelab"];
  };

  security.sudo.wheelNeedsPassword = true;

  users.users.homelab = {
    isNormalUser = true;
    extraGroups = ["wheel"];
    shell = pkgs.bash;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFV04So0lYbwNRgZCElASHeEjeUvS4vlVhjt1yvuit93"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  sops.secrets.tailscale-authkey = {};

  services.tailscale = {
    enable = true;
    authKeyFile = config.sops.secrets.tailscale-authkey.path;
    # No --hostname here: tailscaled defaults to the OS hostname, so the
    # tailnet name follows networking.hostName without a second place to
    # keep in sync. (--name is not a real flag; --hostname is.)
    #
    # These apply on first registration only — tailscaled-autoconnect
    # short-circuits once the node is up, so changing them later needs an
    # explicit `tailscale set`.
    extraUpFlags = ["--ssh" "--advertise-tags=tag:homelab"];
  };

  # Secrets (sops-nix): decrypt using the host's own SSH host key, so
  # there's no separate key to provision/rotate on the machine itself —
  # only the admin key in .sops.yaml (used to author secrets/secrets.yaml)
  # needs separate custody.
  sops.age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
  sops.defaultSopsFile = ../secrets/secrets.yaml;

  environment.systemPackages = with pkgs; [
    kubectl
    k9s
  ];
}
