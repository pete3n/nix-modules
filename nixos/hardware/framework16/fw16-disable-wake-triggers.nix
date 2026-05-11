# Workaround for laptop suspend early wakeup issues
# Disables all wake triggers except the power button
# See: https://community.frame.work/t/guide-framework-laptop-16-suspend-waking-up-early-or-failing-to-suspend-fix/45986/27
{
  lib,
  config,
  pkgs,
  ...
}:

# Exclusion path changed in kernel 7.0.5 — power button moved from
# LNXSYSTM:00/LNXSYBUS:00/PNP0C0C:00 to platform/PNP0C0C:00
# Both patterns included for compatibility with pre-7.0 kernels
let
  cfg = config.services.fw16-disable-wake-triggers;
  disableWakeTriggers =
    pkgs.writeShellScript "fw16-disable-wake-triggers" # sh
      ''
        set -eu
        ${pkgs.findutils}/bin/find /sys/devices -path '*/power/wakeup' \
        ! -path '*/platform/PNP0C0C:00/*' \
        ! -path '*/LNXSYBUS:00/PNP0C0C:00/*' |
        while IFS= read -r _wakeup; do
        	echo disabled > "$_wakeup" 2>/dev/null || true
        done      
      '';
in
{
  options.services.fw16-disable-wake-triggers = {
    enable = lib.mkEnableOption "Disable all wakeup devices except the power button";
  };

  config = lib.mkIf cfg.enable {
    systemd.services.fw16-disable-wake-triggers = {
      description = "Disable wakeup devices except power button.";
      wantedBy = [
        "multi-user.target"
        "sleep.target"
      ];
      before = [ "sleep.target" ];
      after = [ "systemd-udev-settle.service" ];
      wants = [ "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = disableWakeTriggers;
        RemainAfterExit = false;
      };
    };
  };
}
