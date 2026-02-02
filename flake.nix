{
  description = "Pete3n's NixOS + Home Manager modules";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { ... }:
    let
      importModule = path: import path;
    in
    {
      nixosModules = {
        # Default all generic modules
        default = importModule ./nixos/default.nix;

        power-management = {
          lidmond = importModule ./nixos/power-management/lidmond.nix;
        };

        # Hardware specific modules
        hardware = {
          framework16 = {
            fw16-kbd-alsd = importModule ./nixos/hardware/framework16/fw16-kbd-alsd.nix;
            fw16-disable-wake-triggers = importModule ./nixos/hardware/framework16/fw16-disable-wake-triggers.nix;
          };
        };
      };

      homeManagerModules = {
        # Cross-platform HM modules bundle (optional)
        default = importModule ./home-manager/default.nix;

        linux = {
          default = importModule ./home-manager/linux/default.nix;

          power-management = {
							batmond = importModule ./home-manager/linux/power-management/batmond.nix;
            hyprlidmon = importModule ./home-manager/linux/power-management/hyprlidmon.nix;
            hyprSuspendBlocker = importModule ./home-manager/linux/power-management/hyprSuspendBlocker.nix;
          };
        };
      };
    };
}
