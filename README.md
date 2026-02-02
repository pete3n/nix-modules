# Pete3n's Nix Module Repository
This is a collection of my more polished Nix modules for NixOS, Nix-Darwin, 
and Nix Home-manager, taken from my [make-nix](https://github.com/pete3n/make-nix) config.

Currently the NixOS modules moslty focus on Linux power management issues, and
hardware specific quirks for Framework computers. Most of the Home-manager modules are
for use with Hyprland. I will add Nix-Darwin and cross-platform modules in the future.

## NixOS Modules
- [lidmond](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/power-management#lidmond) -- *Lid monitor daemon*: A systemd service designed to replace logind with 
more customizable and flexible control. 
    - *Why?* Because I wanted to only turn off the laptop display when I closed the lid 
    and was on AC power, but I wanted to suspend the laptop when I closed the lid when 
    on battery power, regardless of if I was in a Wayland or Xorg session. 
    I couldn't find a good implementation with existing services, so I made my own.

## NixOS Hardware Modules
- [fw16-kbd-alsd](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/hardware/framework16#fw16-kbd-alsd) -- *Framework16 keyboard ambient light sensor daemon*: 
A systemd service to automate control of the keyboard backlight based on ambient lighting,
battery status, and lid status.
    - *Why?*  Because I wanted automatically control the keyboard backlight to save power
    when on battery (I need a backlight when it is dark, not when it is sunny). 

- [fw16-disable-wake-triggers](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/hardware/framework16#fw16-disable-wake-triggers) -- *Framework16 disable wake triggers service*: 
A one-shot systemd service to disable all wakeup sources except the power button.
    - *Why?* My laptop was constantly waking up prematurely from suspend from sources
    that I couldn't isolate, so I disabled all of them.

## Home-manager Modules
- [batmond](https://github.com/pete3n/nix-modules/tree/nixos-25.11/home-manager/linux/power-management#batmond) -- *Battery monitor daemon*: A systemd user daemon that displays 
    customizable messages and runs customizable commands when different levels of 
    battery discharge are detected. It supports running in both graphical and 
    non-graphical (tty) environments.

    - *Why?* Because my laptop was just dying when the battery drained and I didn't
    notice it. 

- [hyprlidmon](https://github.com/pete3n/nix-modules/tree/nixos-25.11/home-manager/linux/power-management#hyprlidmon) -- *Hyprland lid monitor*: The Home-manager service companion for lidmond.

    - *Why?*  Because I wanted to disable the internal display on my laptop when 
    I closed the lid while on AC power with an external display connected, like
    a docking station. But if I didn't have an external display connected, I wanted
    to just start hyprlock. I had already built lidmond, so this was a natural progression.

- [hyprSuspendBlocker](https://github.com/pete3n/nix-modules/tree/nixos-25.11/home-manager/linux/power-management#hyprSuspendBlocker) -- *Hyprland suspend blocker*: A script to block ```systemctl suspend ```
    given user specified conditions. Intended for use with hypridle.

    - *Why?* Because I wanted to configure hypridle to suspend my laptop after 10 minutes
    if it was on battery power, but not if it was on external AC power.

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

