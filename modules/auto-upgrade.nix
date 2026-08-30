# Pull-based deploy: the machine fetches this flake
# from GitHub and rebuilds on a timer. Outbound HTTPS to github.com only —
# nothing inbound, no deploy keys, no exposed ports.
#
# Using NixOS's built-in system.autoUpgrade rather than a hand-rolled
# timer+service: it already does exactly what was wanted here (flake
# fetch, systemd timer, randomized delay), is better tested, and still
# creates a plain `nixos-upgrade.service` we can hang onFailure= off of
# below — no need to reinvent it.
{...}: {
  system.autoUpgrade = {
    enable = true;
    flake = "github:jamesgibbons92/homelab-nix#sanzang";
    dates = "hourly";
    randomizedDelaySec = "10m";
    persistent = true;

    # Deliberately false: a kernel/nixpkgs bump that lands via the timer
    # restarts k3s (see modules/k3s.nix comment on restart behaviour) and
    # kills every pod already; an unattended *reboot* on top of that would
    # also take out the API server for the duration of a full boot with
    # nobody watching. Kernel updates apply on the next reboot the
    # operator does deliberately.
    allowReboot = false;
  };

  # Failure here is the one thing that must not fail silently — a broken
  # pull-deploy means the host quietly stops receiving changes.
  systemd.services.nixos-upgrade.onFailure = ["notify-failure.service"];
}
