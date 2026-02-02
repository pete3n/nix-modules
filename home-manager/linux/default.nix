{ ... }:
{
  imports = [
		./power-management/batmond.nix
    ./power-management/hyprlidmon.nix
    ./power-management/hyprSuspendBlocker.nix
  ];
}
