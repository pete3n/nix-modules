# Nix Home-manager Linux Power-Management Modules
Power management is one of the bigger struggles I have had using a laptop with
with NixOS. These are Nix Home-manager modules for Linux that attempt to solve
some of the issues I have encountered with power management.

## hyprlidmon
A systemd laptop lid monitor dameon that runs customizable commands when the lid
opens and closes. Requires the [lidmond](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/power-management) module.

### hyprlidmon usage
Follow the [repo instructions](https://github.com/pete3n/nix-modules) to add the module inputs to your flake.
Ensure that lidmond is imported in your system configuration and enabled with:
### configuration.nix:
```
services.lidmond = {
    enable = true;
};
```

You must also disable the logind LidSwitch handlers with:
### configuration.nix:
```
serivices.logind = {
    settings.Login = {
        HandleLidSwitch = "ignore";
        HandleLidSwitchDocked = "ignore";
        HandleLidSwitchExternalPower = "ignore";
    };
};
```
Otherwise they will fight to control lid actions.

Enable hyprlidmon in your Home-manager configuration with:
### home.nix:
```
services.hyprlidmon = {
    enable = true;
};
```
### hyprlidmon customizable options
hyprlidmon provides a number of module options to adjust default behavior:
### home.nix:
```
services.lidmond = {
    enable = true;
    eventDir = "/run/lidmond/events";
    lidClosedDefaultCmd = "hyprlock";
    lidOpenedDefaultCmd = ":";
    pollIntervalSeconds = 1;
    logToJournal = true;
    intDisplay = "eDP-1";
};
```
*eventDir* -- This is the directory that lidmond writes lid events to. *Do not*
change this path unless you have modified lidmond to write to a different directory. 
*NOTE:* your user must be in a group that has read permissions to this directory for 
hyprlidmon to function. This can be configured with the lidmond accessGroup option. 

*lidClosedDefaultCmd* -- If no rule conditions match when the lid is closed, or there are
no conditions defined, then this command will be executed.

*lidOpenedDefaultCmd* -- If no rule conditions match when the lid is opened, or there are
no conditions defined, then this command will be executed.

*pollInternvalSeconds* -- How frequently to check the lid status.

*logToJournal* -- Whether to write output to the systemd journal. These can be viewed with
``` journalctl --user -u hyprlidmon ```

*intDisplay* -- This is the monitor name that hyprctl identifies the internal display with.
This is used by the built-in *--int-display-disable* and *--int-display-enable* functions 
that are arguments that can be called as commands in the cmd lists. By default it will
attempt to auto-detect the internal display, but if it fails you may need to specify it
yourself.

Unlike lidmond, hyprlidmon doesn't provide a opinionated rule list. So you will
definitely want to define your own. Here is an example:
### home.nix:
```
hyprlidmon = {
    enable = true;
    # rules evaluated on lidClosed only; first match wins
    rules = [
        {
		    # "Docked" with AC power and external display attached
            cond = [ "extPower" "extDisplay" ];
            closeCmd = [
                "--int-display-disable"
            ];
            openCmd = [
                "--int-display-enable"
            ];
        }
      ];

    # optional defaults if no rule matches
    lidClosedDefaultCmd = "hyprlock";
    lidOpenedDefaultCmd = ":";
};
```
The rules list contains an attribute set of rules that can be configured. For the commands
to execute, all the rules in the *cond* list must match. 

The example above will disable the internal laptop display when the lid is closed 
and the laptop is connected to AC power and an external display is present. If no external 
display is present or the laptop is on battery, then it will open hyprlock and
also execute any commands from lidmond.

