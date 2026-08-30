# Declarative partitioning for nixos-anywhere. disko wipes this disk on
# every run of `nixos-anywhere --flake .#sanzang` — it is NOT idempotent
# against existing data.
#
# TODO(operator): confirm the real device path with `lsblk` on the actual
# machine before running nixos-anywhere — this is a placeholder. Likely
# /dev/sda for a SATA SSD, or an NVMe path (/dev/nvme0n1).
#
# No LUKS: this host reboots unattended (see modules/auto-upgrade.nix) and
# there is nobody present to type a disk-unlock passphrase after a reboot.
{
  disko.devices = {
    disk = {
      main = {
        device = "/dev/sda";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
                mountOptions = ["umask=0077"];
              };
            };
            root = {
              size = "100%";
              content = {
                # ext4, not xfs: xfs has a known
                # power-loss corruption issue on bare metal, and this
                # laptop will be power-cycled casually.
                type = "filesystem";
                format = "ext4";
                mountpoint = "/";
              };
            };
          };
        };
      };
    };
  };
}
