# Failure notification + dead-man's switch.
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
