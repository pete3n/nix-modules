{
  description = "Pete3n's NixOS + Home Manager modules";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      importModule = path: import path;
    in
    {
      nixosModules = {
        power-management = {
          lidmond = importModule ./nixos/power-management/lidmond.nix;
        };

        # Hardware specific modules
        hardware = {
          framework16 = {
            kbd-alsd = importModule ./nixos/hardware/framework16/fw16-kbd-alsd.nix;
          };
        };

        # Default merge all generic modules
        default = lib.mkMerge [
          (importModule ./nixos/power-management/lidmond.nix)
        ];
      };

      homeManagerModules = {
				# Cross-platform
				default = importModule ./home-manager/default.nix;
        linux = {
					# Merge all generic linux modules
					default = lib.mkMerge [
						(importModule ./home-manager/linux/power-management/hyprlidmon.nix)
					];
          power-management = {
            hyprlidmon = importModule ./home-manager/linux/power-management/hyprlidmon.nix;
          };
        };
      };
    };
}
