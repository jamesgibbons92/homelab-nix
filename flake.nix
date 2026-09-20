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
      # Pinned: sops-nix 16954c1 (2026-09-17) bumped go.mod to Go 1.26, but
      # nixos-25.11 ships Go 1.25, and because of the `follows` below
      # sops-install-secrets is built with *our* nixpkgs — so anything newer
      # fails with "go.mod requires go >= 1.26". Last rev before the bump.
      # Drop the rev once nixpkgs moves to 26.05.
      url = "github:Mic92/sops-nix/13616fff713a9f94055c66f15687ebdc17a335df";
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
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    # Loaded by direnv (`use flake` in .envrc): the CLI tools the README
    # workflow assumes, so they don't need to be installed on the workstation.
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        kubectl
        sops
        age
        ssh-to-age
        nixos-anywhere
      ];
    };

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
