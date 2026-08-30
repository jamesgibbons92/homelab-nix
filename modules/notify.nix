# Failure + success notification, and a dead-man's switch.
#
# ntfy topic and Healthchecks.io ping UUID are sops secrets, not inlined
# here — see secrets/secrets.yaml and the sops.secrets wiring below. Both
# are read from disk at run time so they never land in the Nix store.
{
  config,
  pkgs,
  ...
}: {
  sops.secrets.ntfy-topic = {};
  sops.secrets.healthchecks-uuid = {};

  systemd.services.notify-failure = {
    serviceConfig.Type = "oneshot";
    script = ''
      topic="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.ntfy-topic.path})"
      ${pkgs.curl}/bin/curl -fsS \
        -d "NixOS/k3s failure on ${config.networking.hostName} at $(${pkgs.coreutils}/bin/date). Check: journalctl -u nixos-upgrade -n 100" \
        "ntfy.sh/$topic"
    '';
  };

  # The counterpart to notify-failure, hung off nixos-upgrade's OnSuccess=.
  # nixos-upgrade succeeds every hour whether or not the flake moved, so a
  # bare success ping would be pure noise: this only sends when the system
  # closure the host is running actually changed. The pre-upgrade closure is
  # recorded by nixos-upgrade's ExecStartPre (see modules/auto-upgrade.nix);
  # if it isn't there — someone ran this unit by hand — there's nothing to
  # compare against, so stay quiet rather than guess.
  systemd.services.notify-success = {
    serviceConfig.Type = "oneshot";
    script = ''
      prev_file=/run/nixos-upgrade-prev-system
      [ -r "$prev_file" ] || exit 0

      prev="$(${pkgs.coreutils}/bin/cat "$prev_file")"
      current="$(${pkgs.coreutils}/bin/readlink -f /run/current-system)"
      [ "$prev" = "$current" ] && exit 0

      # diff-closures colours its output unconditionally (it ignores NO_COLOR),
      # and this ends up in a phone notification rather than a terminal: strip
      # the escapes, and keep it to a glance's worth of lines.
      changes="$(${config.nix.package}/bin/nix store diff-closures "$prev" "$current" 2>/dev/null \
        | ${pkgs.gnused}/bin/sed -e 's/\x1b\[[0-9;]*m//g' \
        | ${pkgs.coreutils}/bin/head -n 15)"

      topic="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.ntfy-topic.path})"
      ${pkgs.curl}/bin/curl -fsS \
        -d "NixOS update applied on ${config.networking.hostName} at $(${pkgs.coreutils}/bin/date).
      $changes" \
        "ntfy.sh/$topic"
    '';
  };

  # Surface both a broken pull-deploy and a crashed cluster, not just one.
  systemd.services.k3s.onFailure = ["notify-failure.service"];

  systemd.timers.healthcheck-ping = {
    wantedBy = ["timers.target"];
    timerConfig = {
      OnCalendar = "*:0/5";
      Persistent = true;
    };
  };

  systemd.services.healthcheck-ping = {
    serviceConfig.Type = "oneshot";
    script = ''
      uuid="$(${pkgs.coreutils}/bin/cat ${config.sops.secrets.healthchecks-uuid.path})"
      ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 "https://hc-ping.com/$uuid"
    '';
  };
}
