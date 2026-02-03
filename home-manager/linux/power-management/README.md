# Nix Home-manager Linux Power-Management Modules
Power management is one of the bigger struggles I have had using a laptop with
with NixOS. These are Nix Home-manager modules for Linux that attempt to solve
some of the issues I have encountered with power management.

# hyprlidmon
A systemd laptop lid monitor daemon that runs customizable commands when the lid
opens and closes. Requires the [lidmond](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/power-management) NixOS module.

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
hyprlidmon to function. This can be configured with the [lidmond accessGroup](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/power-management#lidmond-customizable-options) option. 

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
services.hyprlidmon = {
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


# hyprSuspendBlocker
A wrapper script for ``` systemctl suspend ``` that blocks suspend if user specified 
conditions are met. It is intended for use with programs like hypridle.

### hyprSuspendBlocker usage
Follow the [repo instructions](https://github.com/pete3n/nix-modules) to add the 
module inputs to your flake. Ensure that the home modules are imported in your 
Home-manager configuration and enable hyprSuspendBlocker with:
### home.nix:
```
programs.hyprSuspendBlocker = {
    enable = true;
};
```
This is all you need to use the default configuration which will prevent suspend
when the system is on AC power. 

You can now utilize it in your hypridle config like:
### home.nix:
```
{
    services.hypridle = {
        enable = true;
        settings = {
            listener = [
                {
                    timeout = 600; # 10min
                    on-timeout = "hypr-suspend-blocker";
                }
            ];
        };
    };
}
```
### hyprSuspendBlocker customizable options
hyprSuspendBlocker provides two options to control behavior:
### home.nix:
```
programs.hyprSuspendBlocker = {
    enable = true;
    intDisplay = "eDP-1";
    blockers = [
        [ "lidOpen" ]
        [ "lidClosed" ]
        [ "extDisplay" ]
        [ "extPower" ]
        [ "onBattery" ]
    ];
};
```
*intDisplay* -- This value is used to determine if an external display is connected.
It is derived from the monitor name that hyprctl identifies the internal display with.
By default the module will attempt to auto-detect the internal display, but if it fails 
you may need to specify it yourself.

*blockers* -- This is a list of lists containing conditions to check. All supported
values are shown in the example above. If a list contains multiple condition elements, 
then all the condition elements must be true for the list to be true and block suspend.
If there are multiple lists of conditions, if any of the lists are true, then
suspend will be blocked. *NOTE:* this doesn't actually block ``` systemctl suspend ```
it just won't be called by the ``` hypr-suspend-blocker ``` script.

The following is a functional example of blockers that will prevent suspend if
a system is on external power or if an external display is attached and the 
laptop lid is closed:
### home.nix:
```
programs.hyprSuspendBlocker = {
    enable = true;
    blockers = [
        [ "extPower" ]
        [ "extDisplay" "lidClosed" ]
    ];
};
```


# batmond
A systemd user daemon that displays customizable messages and runs customizable 
commands when different levels of battery discharge are detected.
It supports running in both graphical and non-graphical (tty) environments.

### batmond usage
Follow the [repo instructions](https://github.com/pete3n/nix-modules) to add the module inputs to your flake.
Ensure that the home modules are imported in your Home-manager configuration 
and enable batmond with:
### home.nix:
```
services.batmond = {
    enable = true;
};
```
This is all that is necessary to use the default configuration.

batmond provides a number of module options to adjust default behavior:
### home.nix:
```
services.batmond = {
    enable = true;
    batteryInterval = 30;
    logEvents =  true;
    guiNotifyCmd = "${pkgs.libnotify}/bin/notify-send -u critical";
    ttyNotifyCmd = "${pkgs.util-linux}/bin/wall -n";
    warnBelowPercent = 15;
    warnBelowGuiMsg = "🪫‼️ Warning battery is running low!";
    warnBelowTtyMsg = "!! Warning battery is running low!";
    suspendPercent = 10;
    suspendSubCmd = "suspend";
    suspendTtyMsg = "Battery low. Suspending system...";
    suspendGuiMsg = "🪫‼️ Batter low. 🌙 Suspending system...";
    hibernatePercent = 0;
    hibernateSubCmd = "hibernate";
    hibernateTtyMsg = "Battery severely low. Hibernating system...";
    hibernateGuiMsg = "🪫‼️ Batter severely low.  Hibernating system...";
    shutdownPercent = 1;
    shutdownSubCmd = "poweroff";
    shutdownGuiMsg = "🪫‼️ Battery critically low. ⏻ Shutting down...";
    shutdownTtyMsg = "Battery critically low. Shutting down system...";
};
```
*batteryInterval* -- How frequently (in seconds) to check the battery discharge level.

*logEvents* -- Whether to log daemon events. These can be read with ```journalctl --user -t batmond```

*guiNotifyCmd* -- The command to run to display notifications in a graphical environment.

*ttyNotifyCmd* -- The command to run to display notifications in a tty envvironment.

*warnBelowPercent* -- The remaining battery capacity below which warnings will begin to be send.

*warnBelowGuiMsg* -- The battery warning message to display in GUI environments.

*warnBelowTtyMsg* -- The battery warning message to display in TTY environments.

*suspendPercent*  -- The remaining battery capacity at which the suspend command will be run (0 disables).

*suspendSubCmd* -- The ```systemctl``` subcommand to run to suspend the system.

*suspendTtyMsg* -- The suspend notification message to display in TTY environments. 

*suspendGuiMsg* -- The suspend notification message to display in GUI environments.

*hibernatePercent* -- The remaining battery capacity at which the hibernate command will be run (0 disables).

*hibernateSubCmd* -- The ```systemctl``` subcommand to run to hibernate the system.

*hibernateTtyMsg* -- The suspend notification message to display in TTY environments. 

*hibernateGuiMsg* -- The suspend notification message to display in GUI environments.

*shutdownPercent* -- The remaining battery capacity at which the shutdown command will be run (0 disables).

*shutdownSubCmd* -- The ```systemctl``` subcommand to run to shutdown the system.

*shutdownGuiMsg* -- The shutdown notification message to display in GUI environments. 

*shutdownTtyMsg* -- The shutdown notification message to display in TTY environments. 


# powerproud
A systemd user daemon that automatically switches power-profiles and adjusts screen 
brightness based on the battery charging status. Requires power-profiles-daemon.

### powerproud usage
Follow the [repo instructions](https://github.com/pete3n/nix-modules) to add the module inputs to your flake.
Ensure that the home modules are imported in your Home-manager configuration 
and enable powerproud with:
### home.nix:
```
services.powerproud = {
    enable = true;
};
```
This is all that is necessary to use the default configuration.

If you are using NixOS, ensure that power-profiles-daemon is enabled in your system 
configuration with:
### configuration.nix:
```
services.power-profiles-daemon = {
    enable = true;
};
```
### Troubleshooting
If powerproud is not functioning as expected, you can check logs with ```journalctl --user -t powerproud```
If you see logs similar to this:
```
bat_state=charging cmd=powerprofiles set performance (failed)
bat_state=unknown cmd=power-profiles-daemon inactive; will manage brightness only
```
The power-profiles-daemon is either not running or not being detected correctly.

powerproud provides a number of module options to adjust default behavior:
```
### home.nix
services.powerproud = {
    enable = true;
    logEvents = true;
    batPollInterval = 5;
    onBatteryProfile = "power-saver";
    onAcProfile = "performance";
    onBatteryBrightness = 50;
    onAcBrightness = 100;
}
```
*logEvents* -- Whether to log events for journalctl

*batPollInterval* -- How frequently (in seconds) to check the battery status

*onBatteryProfile* -- The power profile to switch to when the battery is discharging

available profiles can be seen with: ```powerprofilesctl list```

*onAcProfile* -- The power profile to switch to when the battery is charging.

*onBatteryBrightness* -- The screen backlight brightness to set when the battery is 
discharging. NOTE: This will only decrease brightness to the specified level.

*onAcBrigthness* -- The screen backlight brightness to set when the battery is charging.
NOTE: This will only increase the screen brigthness to the desire level.
