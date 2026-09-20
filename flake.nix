{
  description = "Homelab: NixOS + k3s on sanzang";

  inputs = {
    # Stable, not unstable: this host auto-upgrades unattended (see
    # modules/auto-upgrade.nix) and every nixpkgs bump that touches k3s
    # restarts the whole cluster (see modules/k3s.nix). Stable minimizes
    # how often that happens.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Only used to build the one-off kexec bootstrap image (see
    # hosts/sanzang/kexec-installer.nix) — not part of the deployed system,
    # so it isn't pinned to `nixpkgs` above.
    nixos-images.url = "github:nix-community/nixos-images";
  };

  outputs = {
    self,
    nixpkgs,
    disko,
    sops-nix,
    nixos-images,
    ...
  } @ inputs: let
    system = "x86_64-linux";
  in {
    nixosConfigurations = {
      sanzang = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {inherit inputs;};
        modules = [
          disko.nixosModules.disko
          sops-nix.nixosModules.sops
          ./hosts/sanzang/configuration.nix
          ./hosts/sanzang/disko.nix
          ./modules/common.nix
          ./modules/k3s.nix
          ./modules/tailscale-operator.nix
          ./modules/media.nix
          ./modules/auto-upgrade.nix
          ./modules/notify.nix
        ];
      };
    };

    # Custom kexec installer to enable wifi - bit of a hack but I don't have an ethernet adaptor for this mac atm
    packages.${system}.kexec-installer =
      (nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [
          nixos-images.nixosModules.kexec-installer
          ./hosts/sanzang/kexec-installer.nix
        ];
      })
      .config
      .system
      .build
      .kexecInstallerTarball;
  };
}
