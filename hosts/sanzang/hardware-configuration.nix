# PLACEHOLDER — do not trust these values. Regenerate on the real machine
# with `nixos-generate-config --no-filesystems --show-hardware-config`
# (the --no-filesystems flag matters: disko.nix owns fileSystems/swapDevices,
# duplicating them here will conflict) and replace this file's contents.
#
# The kernel modules below are carried over from an earlier NixOS install on
# the same chassis as a starting guess, not a verified value.
{
  config,
  lib,
  modulesPath,
  ...
}: {
  imports = [(modulesPath + "/installer/scan/not-detected.nix")];

  boot.initrd.availableKernelModules = ["xhci_pci" "ehci_pci" "ahci" "usbhid" "usb_storage" "sd_mod"];
  boot.initrd.kernelModules = [];
  boot.kernelModules = ["kvm-intel" "b43"];
  networking.enableB43Firmware = true;

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}
