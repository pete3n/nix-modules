# NixOS Framework16 Modules
These modules apply specifically to Framework16 laptops. The [NixOS Hardware Repo](https://github.com/NixOS/nixos-hardware/tree/master/framework/16-inch)
also provides a useful repository for Framework hardware configuration.

## fw16-kbd-alsd
A systemd service to automate adjustment of the Framework16 keyboard backlight based
on values from the ambient light sensor. This will always disable the backlight if the
laptop lid closes.

### fw16-kbd-alsd usage
Follow the [repo instructions](https://github.com/pete3n/nix-modules) to add the module inputs to your flake.
Once added and imported in your system configuration, you can enable fw16-kbd-alsd with:
### configuration.nix:
```
services.fw16-kbd-alsd = {
    enable = true;
};
```
This is all that is necessary to use the default configuration. 

### fw16-kbd-alsd customizable options
fw16-kbd-alsd provides a number of module options to adjust default behavior:
### configuration.nix:
```
services.fw16-kbd-alsd = {
    enable = true;
    vid = "32ac";
    alsPath = "/sys/bus/iio/devices/iio:device0/in_illuminance_raw";
    pollIntervalSeconds = 5;
    hysteresis = 1;
    noLight = 100;
    lowLight = 75;
    dimLight = 50;
    brightLight = 25;
    sunLight = 0;
    batteryOnly = true;
    acDefault = 100; 
};
```
*vid* -- Vendor ID for the keyboard from qmk_hid:
```
32ac:0012
  Manufacturer: "Framework"
  Product:      "Laptop 16 Keyboard Module - ANSI"
  FW Version:   0.3.1
  Serial No:    "FRAKDKEN0100000000"
```

*alsPath* -- Path to the system's ambient light sensor.

*pollInternvalSeconds* -- How frequently to check the ambient light sensor.

*hysteresis* -- Adjustment to prevent fluctuations in the ALS measurements. If
the backlight is consistently hopping between brightness, try increasing this value.

*noLight* -- Backlight brightness for very dark ambient lighting.

*lowLight* -- Backlight brightness for dark ambient lighting.

*dimLight* -- Backlight brightness for dim ambient lighting.

*brightLight* -- Backlight brightness for bright ambient lighting.

*sunLight* -- Backlight brightness for very bright (sunlight) ambient lighting.

*batteryOnly* -- Only apply ambient light settings when the laptop is on battery.

*acDefault* -- Default brightness to apply when not running on battery.

## fw16-disable-wake-triggers
A one-shot systemd service to disable all wake sources except the power button.
Prevent premature wakeup from suspend. This may work with other model frameworks
but I have only tested this on a Framework16 with a Ryzen AI 300 mainboard. 

### fw16-disable-wake-triggers
Follow the [repo instructions](https://github.com/pete3n/nix-modules) to add the module inputs to your flake.
Once added and imported in your system configuration, you can enable fw16-disable-wake-triggers with:
### configuration.nix:
```
services.fw16-disable-wake-triggers = {
    enable = true;
};
```
There are no additional options. The service runs once at boot and 
disables everything but the power button for suspend resume until a reboot.
