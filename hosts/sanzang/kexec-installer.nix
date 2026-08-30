{
  config,
  lib,
  pkgs,
  ...
}: {
  # Extends nix-community/nixos-images' stock kexec-installer (wired/DHCP
  # only, via systemd-networkd) so nixos-anywhere's bootstrap environment can
  # actually see the target's wifi. Built as `.#kexec-installer`
  # (see flake.nix) and passed to nixos-anywhere with `--kexec <tarball>`
  system.kexec-installer.name = "sanzang-wifi-installer";

  # Once booted, connect interactively with e.g.:
  #   iwctl --passphrase YOUR_WIFI_PASSWORD station wlan0 connect YOUR_SSID
  networking.wireless.iwd.enable = true;

  # The base netboot-minimal profile (imported via nixos-images'
  # kexec-installer module) sets this to false at priority 70 to keep
  # netboot images small — a plain `= true` here loses to that (default
  # priority 100 is weaker), so it must be forced.
  hardware.enableRedistributableFirmware = lib.mkForce true;
  nixpkgs.config.allowUnfree = true;
  boot.kernelModules = ["b43"];
  networking.enableB43Firmware = true;
}
