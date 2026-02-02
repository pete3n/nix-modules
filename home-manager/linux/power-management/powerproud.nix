# Power profiles user daemon.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkOption
    mkEnableOption
    mkIf
    types
    ;

  hasPPD =
    config ? services
    && config.services ? "power-profiles-daemon"
    && config.services."power-profiles-daemon" ? enable;

  ppdEnabled = hasPPD && config.services."power-profiles-daemon".enable;
  
	cfg = config.services."powerproud";
  powerproud =
    pkgs.writeShellScriptBin "powerproud" # sh
      ''
        set -eu

        ON_BATTERY_BRIGHTNESS="${toString cfg.onBatteryBrightness}"
        ON_AC_BRIGHTNESS="${toString cfg.onAcBrightness}"
        ON_BATTERY_PROFILE="${toString cfg.onBatteryProfile}"
        ON_AC_PROFILE="${toString cfg.onAcProfile}"
				BAT_POLL_INTERVAL="${toString cfg.batPollInterval}"

				bat_dir=""
				bat_state=""

				log() {
					${lib.optionalString cfg.logEvents #sh 
					''
						_bat_state="$1" 
						_action="$2"
						${pkgs.util-linux}/bin/logger -t powerproud -- "bat_state=$_bat_state cmd=$_action"
					''}

					# Logging disabled
					${lib.optionalString (!cfg.logEvents) '' : ''}
				}

				find_battery_dir() {
					for _dev in /sys/class/power_supply/*; do
						[ -r "$_dev/type" ] || continue
						[ "$(${pkgs.coreutils}/bin/cat "$_dev/type" 2>/dev/null || true)" = "Battery" ] || continue
						printf '%s\n' "$_dev"
						return 0
					done
					return 1
				}

				init_battery_dir() {
					bat_dir="$(find_battery_dir 2>/dev/null || true)"
					[ -n "$bat_dir" ] || return 1
					return 0
				}

				get_bat_state() {
					[ -n "$bat_dir" ] || { printf 'unknown\n'; return 0; }

					_state="$(cat "$bat_dir/status" 2>/dev/null || true)"
					case "$_state" in
						Discharging) printf 'discharging\n' ;;
						Charging|Full) printf 'charging\n' ;;
						*) printf 'unknown\n' ;;
					esac
				}

        get_brightness_percent() {
					_cur=$(${pkgs.brightnessctl}/bin/brightnessctl g)
					_max=$(${pkgs.brightnessctl}/bin/brightnessctl m)
					# Error state, prevent div by zero when max is zero
					[ "$_max" -gt 0 ] || { printf '0\n'; return 0; }
					printf "%s\n" $(( _cur * 100 / _max ))
        }

        discharging_actions() {
					_cur_percent=$(get_brightness_percent)
					if [ "$_cur_percent" -gt "$ON_BATTERY_BRIGHTNESS" ]; then 

						if ${pkgs.brightnessctl}/bin/brightnessctl s "$ON_BATTERY_BRIGHTNESS%" >/dev/null 2>&1; then
							log "discharging" "brightnessctl s $ON_BATTERY_BRIGHTNESS%"
						else
							log "discharging" "brightnessctl s $ON_BATTERY_BRIGHTNESS% (failed)"
						fi
					fi

					if ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set "$ON_BATTERY_PROFILE" >/dev/null 2>&1; then
						log "discharging" "powerprofilesctl set $ON_BATTERY_PROFILE"
					else
						log "discharging" "powerprofilesctl set $ON_BATTERY_PROFILE (failed)"
					fi
        }

        charging_actions() {
					if ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set "$ON_AC_PROFILE" >/dev/null 2>&1; then
						log "charging" "powerprofiles set $ON_AC_PROFILE"
					else
						log "charging" "powerprofiles set $ON_AC_PROFILE (failed)"
					fi
				
					if ${pkgs.brightnessctl}/bin/brightnessctl s "$ON_AC_BRIGHTNESS%" >/dev/null 2>&1; then
						log "charging" "brightnessctl s $ON_AC_BRIGHTNESS%"
					else
						log "charging" "brightnessctl s $ON_AC_BRIGHTNESS% (failed)"
					fi
        }

				# Get initial state
				init_battery_dir || exit 0 # Exit on no battery
				bat_state="$(get_bat_state)"
				case "$bat_state" in
					discharging) discharging_actions ;;
					charging)    charging_actions ;;
				esac

				while ${pkgs.coreutils}/bin/sleep "$BAT_POLL_INTERVAL"; do
					_new_state="$(get_bat_state)"

					# Ignore unknown states
					case "$_new_state" in
						discharging|charging) : ;;
						*) continue ;;
					esac

					[ "$_new_state" = "$bat_state" ] && continue
					bat_state="$_new_state"

					case "$bat_state" in
						discharging) discharging_actions ;;
						charging)    charging_actions ;;
					esac
				done
      '';
in
{
  options.services."powerproud" = {
    enable = mkEnableOption "Enable powerprofile user daemon.";

		logEvents = mkOption {
			type = types.bool;
			default = true;
			description = ''
				Whether to log events with logger -t powerproud

				Default: true
			'';
		};

    batPollInterval = mkOption {
      type = types.ints.positive;
      default = 5;
      description = ''
        How often (in seconds) to check battery status.

        Default: 5
      '';
    };

    onBatteryProfile = mkOption {
      type = types.enum [
        "power-saver"
        "balanced"
        "performance"
      ];
      default = "power-saver";
      description = ''
        Powerprofile to switch to when on battery.
        One of: "power-saver", "balanced", or "performance"

				Default: power-saver
      '';
    };

    onAcProfile = mkOption {
      type = types.enum [
        "power-saver"
        "balanced"
        "performance"
      ];
      default = "performance";
      description = ''
        Powerprofile to switch to when on AC power.
        One of: "power-saver", "balanced", or "performance" 

				Default: performance
      '';
    };

    onBatteryBrightness = mkOption {
      type = types.ints.between 1 100;
      default = 50;
      description = ''
        Screen backlight brightness to switch to when on battery.
        Range: 1 - 100

				Default: 50
      '';
    };

    onAcBrightness = mkOption {
      type = types.ints.between 1 100;
      default = 100;
      description = ''
        Brightness to switch to when on AC power.
        Range: 1 - 100

				Default: 100
      '';
    };
  };

  config = mkIf cfg.enable {
		assertions = [
			{
				assertion = (!hasPPD) || ppdEnabled;
				message = ''
					powerproud requires the system service power-profiles-daemon.

					Enable it in your NixOS configuration:
						services.power-profiles-daemon.enable = true;
				'';
			}
		];

    home.packages = [
      powerproud
    ];

    systemd.user.services."powerproud" = {
      Unit = {
        Description = "Powerprofiles user daemon to auto-switch power profiles.";
      };
      Service = {
        Type = "simple";
				ExecStart = "${powerproud}/bin/powerproud";
        Restart = "always";
        RestartSec = 2;
      };
      Install = {
        WantedBy = [ "default.target" ];
      };
    };
  };
}
