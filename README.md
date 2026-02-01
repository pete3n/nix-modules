# Pete3n's Nix Module Repository
This is a collection of my more polished Nix modules for NixOS, Nix-Darwin, 
and Nix Home-manager take from my [make-nix](https://github.com/pete3n/make-nix) config.
Currently the NixOS modules moslty focus on Linux power management issues, and
hardware specific quirks for Framework computers. Most of the Home-manager modules are
for use with Hyprland. I will add Nix-Darwin and cross-platform modules in the future.

## Featured Modules
- [lidmond](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/power-management) -- *Lid monitor daemon*: A systemd service designed to replace logind with 
more customizable and flexible control. I wanted to only turn off the laptop display
when I closed the lid and was on AC power, but I wanted to suspend the laptop when 
I closed the lid when on battery power, regardless of if I was in a Wayland or Xorg session.
I couldn't find a good implementation with existing services, so I made my own.
- [hyprlidmon](https://github.com/pete3n/nix-modules/tree/nixos-25.11/home-manager/linux/power-management)-- *Hyprland lid monitor*: The Home-manager service companion for lidmond 
that provides a systemd user service to integrate with Hyprland and lidmond. It provides
flexible and customizable control of lid events. I wanted to disable the internal
display on my laptop when I closed the lid with an external display connected AND was
on AC power (docking station), but start hyprlock if I didn't have an external display
connected. I had already built lidmond, so this was a natural progression.

## Usage
You can utilize these modules by adding is repo as an input to your flake.nix,
such as:

### flake.nix:
```
inputs.pete3n-mods = {
    url = "github:pete3n/nix-modules?ref=nixos-25.11";
	inputs.nixpkgs.follows = "nixpkgs";
};
```

For NixOS you can pass inputs to your system configuration file and import the 
desired modules like:
### configuration.nix:
```
{ inputs, ... }:
{
    imports = [
        inputs.pete3n-mods.nixosModules.default
    ];
}
```

This imports all the general purpose modules that I will implement for NixOS. This
will exclude hardware specific modules which you will have to import individual like:
### configuration.nix:
```
{ inputs, ... }:
{
    imports = [
        inputs.pete3n-mods.nixosModules.hardware.framework16.fw16-kbd-alsd
    ];
}
```
For Home-manager modules, the pattern is similar:
### home.nix:
```
{ inputs, ... }:
{
    imports = [
        inputs.pete3n-mods.homeManagerModules.linux.default
    ];
}
```
This will import all the general purpose Home-manager modules for Linux. 
For cross-platform modules import:
### home.nix:
```
{ inputs, ... }:
{
    imports = [
        inputs.pete3n-mods.homeManagerModules.default
    ];
}
```

