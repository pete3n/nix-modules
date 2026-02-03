# NixOS Power-Management Modules
Power management is one of the bigger struggles I have had using a laptop with
with NixOS. These modules provide some solutions I have created to provide better
power management control. There are also [hardware](https://github.com/pete3n/nix-modules/tree/nixos-25.11/nixos/hardware) specific modules that address power
issues as well.

## lidmond
A systemd laptop lid monitor daemon that runs customizable commands when the lid
opens and closes.

### lidmond usage
Follow the [repo instructions](https://github.com/pete3n/nix-modules) to add the module inputs to your flake.
Once added and imported in your system configuration, you can enable lidmond with:
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
This is all that is necessary to use the default configuration. 

### lidmond customizable options
lidmond provides a number of module options to adjust default behavior:
### configuration.nix:
```
services.lidmond = {
    enable = true;
    accessGroup = "wheel";
    lidClosedDefaultCmd = "systemctl suspend";
    lidOpenedDefaultCmd = ":";
    pollIntervalSeconds = 1;
    logToJournal = true;
    backlightDevice = "nvidia_wmi_ec_backlight";
};
```
*accessGroup* -- This is the group that will have permission to access lid events written
to */run/lidmond/events* by the daemon. When using [hyprlidmon](https://github.com/pete3n/nix-modules/tree/nixos-25.11/home-manager/linux/power-management) you must ensure that
your user is a member of this group. The default is the service group "lidmond".

*lidClosedDefaultCmd* -- If no rule conditions match when the lid is closed, or there are
no conditions defined, then this command will be executed.

*lidOpenedDefaultCmd* -- If no rule conditions match when the lid is opened, or there are
no conditions defined, then this command will be executed.

*pollInternvalSeconds* -- How frequently to check the lid status.

*logToJournal* -- Whether to write output to the systemd journal. These can be viewed with
``` journalctl -u lidmond ```

*backlightDevice* -- This is the laptop backlight device to use with the builtin
``` lidmond --backlight-on ``` and  ``` lidmond --backlight-off ``` commands. By 
default this will attempt to auto-detect the correct device.

lidmond provides a rule list with an attribute set of rules that can be configured:
### configuration.nix:
```
services.lidmond = {
    enable = true;
    rules = [
	    {
		    # On AC power: turn backlight off when lid closes, restore on open
			cond = [ "extPower" ];
			closeCmd = [ "lidmond --backlight-off" ];
			openCmd  = [ "lidmond --backlight-on" ];
		}
	];
};
```
For the command to execute, all the rules in the *cond* list must match. However, only
only extPower is currently implemented. If the rule matches then the commands in the closeCmd
list will be executed, and the commands in the openCmd list will be saved to a state file and
executed when the lid is re-opened.

The example shown above is the default rule for the module.
