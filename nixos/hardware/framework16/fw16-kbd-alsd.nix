{ lib, pkgs, config, ... }:

let
  cfg = config.services.fw16-kbd-alsd;
	
  fw16KbdAlsd = pkgs.writeShellScript "fw16-kbd-alsd" ''
    set -eu

    ALS_PATH="${cfg.alsPath}"
    HYST="${toString cfg.hysteresis}"
    QMK="${pkgs.qmk_hid}/bin/qmk_hid"
    VID="${cfg.vid}"
		BATTERY_ONLY="${lib.boolToString cfg.batteryOnly}"
		AC_DEFAULT="${toString cfg.acDefault}"
		STATE_DIR="/run/fw16-kbd-alsd"
		STATE_FILE="$STATE_DIR/last_bucket"
		MISSING_STAMP="$STATE_DIR/qmk-missing.logged"

		qmk_backlight_read() {
			"$QMK" --vid "$VID" via --backlight 2>/dev/null | tr -dc '0-9'
		}

		check_lid() {
			for _file in /proc/acpi/button/lid/*/state; do
				[ -r "$_file" ] || continue
				_state="$(${pkgs.gawk}/bin/awk '{print $2}' "$_file" 2>/dev/null || true)"
				case "$_state" in
					open|closed) printf '%s\n' "$_state"; return 0 ;;
				esac
			done
			printf "unknown\n"
		}

		lid_state="$(check_lid)"
		if [ "$lid_state" = "closed" ]; then
			# Lid closed: always turn keyboard backlight off to save power
			"$QMK" --vid "$VID" via --backlight 0 >/dev/null 2>&1 || true
			exit 0
		fi

		detect_power() {
			# AC if any "online" is 1
			for _file in /sys/class/power_supply/*/online; do
				[ -r "$_file" ] || continue
				_online="$(${pkgs.coreutils}/bin/cat "$_file" 2>/dev/null || true)"
				[ "$_online" = "1" ] && { printf "ac\n"; return 0; }
			done

			# Battery if a Battery device exists and no AC online
			for _type in /sys/class/power_supply/*/type; do
				[ -r "$_type" ] || continue
				[ "$(${pkgs.coreutils}/bin/cat "$_type" 2>/dev/null || true)" = "Battery" ] && { printf "battery\n"; return 0; }
			done

			printf "unknown\n"
		}

		power_state="$(detect_power)"
		if [ "''${BATTERY_ONLY:-false}" = "true" ] && [ "$power_state" = "ac" ]; then
			printf "AC charging detected\n"
			"$QMK" --vid "$VID" via --backlight "$AC_DEFAULT" >/dev/null 2>&1 || true
			exit 0
		fi

		cur="$(qmk_backlight_read || true)"
		if [ -z "$cur" ]; then
			# Device missing or qmk_hid couldn't talk to it
			if [ ! -e "$MISSING_STAMP" ]; then
				printf 'fw16-kbd-als: qmk_hid backlight device not available (vid=%s). Will retry silently.\n' "$VID" >&2
				: >"$MISSING_STAMP"
			fi
			exit 0
		else
			# Device is back; clear missing stamp if it exists
			[ -e "$MISSING_STAMP" ] && rm -f "$MISSING_STAMP" || true
		fi

    # Read ALS value
    if [ ! -r "$ALS_PATH" ]; then
      exit 0
    fi

    _als_path="$(${pkgs.coreutils}/bin/cat "$ALS_PATH" 2>/dev/null || true)"
    case "$_als_path" in
      ""|*[!0-9]*) exit 0 ;;
    esac
    als="$_als_path"

    # Determine raw bucket from ALS (0=dark, 20+=bright)
    if [ "$als" -ge 20 ]; then
      bucket=4
    elif [ "$als" -ge 15 ]; then
      bucket=3
    elif [ "$als" -ge 10 ]; then
      bucket=2
    elif [ "$als" -ge 5 ]; then
      bucket=1
    else
      bucket=0
    fi

		last_bucket=""
		if [ -r "$STATE_FILE" ]; then
			last_bucket="$(cat "$STATE_FILE" 2>/dev/null || true)"
			case "$last_bucket" in
				0|1|2|3|4) : ;;
				*) last_bucket="" ;;
			esac
		fi

    # Apply hysteresis (margin in ALS raw units)
    if [ -n "$last_bucket" ] && [ "$HYST" -gt 0 ] && [ "$bucket" -ne "$last_bucket" ]; then
      if [ "$bucket" -gt "$last_bucket" ]; then
        # Getting brighter: require als >= lower bound of new bucket + HYST
        case "$bucket" in
          1) need=$((5 + HYST)) ;;
          2) need=$((10 + HYST)) ;;
          3) need=$((15 + HYST)) ;;
          4) need=$((20 + HYST)) ;;
        esac
        if [ "$als" -lt "$need" ]; then
          bucket="$last_bucket"
        fi
      else
        # Getting darker: require als <= upper bound of new bucket - HYST
        case "$bucket" in
          0) need=$((4 - HYST)) ;;
          1) need=$((9 - HYST)) ;;
          2) need=$((14 - HYST)) ;;
          3) need=$((19 - HYST)) ;;
        esac
        if [ "$need" -lt 0 ]; then need=0; fi
        if [ "$als" -gt "$need" ]; then
          bucket="$last_bucket"
        fi
      fi
    fi

		printf '%s\n' "$bucket" >"$STATE_FILE"

    # Map bucket -> target backlight (0-100)
    case "$bucket" in
      0) target="${toString cfg.nolight}" ;;
      1) target="${toString cfg.lowlight}" ;;
      2) target="${toString cfg.dimlight}" ;;
      3) target="${toString cfg.brightlight}" ;;
      4) target="${toString cfg.sunlight}" ;;
      *) exit 0 ;;
    esac

    # Read current backlight (best-effort)
    _cur="$("$QMK" --vid "$VID" via --backlight 2>/dev/null | tr -dc '0-9' || true)"
    # If already at target, do nothing
    if [ -n "$_cur" ] && [ "$_cur" = "$target" ]; then
      exit 0
    fi

    # Set backlight (best-effort)
    "$QMK" --vid "$VID" via --backlight "$target" >/dev/null 2>&1 || true
  '';
in
{
  options.services.fw16-kbd-alsd = {
    enable = lib.mkEnableOption "Framework 16 keyboard backlight auto-control via ALS and qmk_hid";

    vid = lib.mkOption {
      type = lib.types.str;
      default = "32ac";
			example = "32ac";
      description = ''
				USB vendor ID passed to qmk_hid.
				See your device list with qmk_hid -l for example:
				3434:0e20
					Manufacturer: "Keychron"
					Product:      "Keychron K2 HE"
					FW Version:   1.0.0
					Serial No:    ""
				32ac:0012
					Manufacturer: "Framework"
					Product:      "Laptop 16 Keyboard Module - ANSI"
					FW Version:   0.3.1
					Serial No:    "FRAKDKEN0100000000

				Default: 32ac
			'';
    };

    alsPath = lib.mkOption {
      type = lib.types.str;
      default = "/sys/bus/iio/devices/iio:device0/in_illuminance_raw";
			example = "/sys/bus/iio/devices/iio:device0/in_illuminance_raw";
      description = ''
				Path to ambient light sensor raw illuminance value.
				Default: /sys/bus/iio/devices/iio:device0/in_illuminance_raw
			'';
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.int;
      default = 5;
			example = 5;
      description = ''
				How frequently to check for ALS changes. 
				Default: 5
			'';
    };

    hysteresis = lib.mkOption {
      type = lib.types.ints.between 0 5;
      default = 1;
			example = 1;
      description = ''
				Hysteresis margin in ALS raw units (0 disables). 
				This helps prevent flapping between between brightness groups.
				Default: 1
			'';
    };

    nolight = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 100;
			example = 100;
      description = ''
				Backlight level when ALS is 0-4 (dark). 
				Default: 100
			'';
    };

    lowlight = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 75;
			example = 75;
      description = ''
				Backlight level when ALS is 5-9 (low-light). 
				Default: 75
			'';
    };

    dimlight = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 50;
			example = 50;
      description = ''
				Backlight level when ALS is 10-14 (dim-light). 
				Default: 50
			'';
    };

    brightlight = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 25;
			example = 25;
      description = ''
				Backlight level when ALS is 15-19 (bright-light). 
				Default: 25
			'';
    };

    sunlight = lib.mkOption {
      type = lib.types.ints.between 0 100;
      default = 0;
			example = 0;
      description = ''
				Backlight level when ALS >= 20 (sunlight). 
				Default: 0
			'';
    };

		batteryOnly = lib.mkOption {
			type = lib.types.bool;
			default = true;
			example = true;
			description = ''
				Only apply settings when on battery power. 
				Default: true"
			'';
		};

		acDefault = lib.mkOption {
			type = lib.types.ints.between 0 100;
			default = 100;
			example = 100;
			description = ''
				Backlight level when AC charger is plugged in. Only applies if batteryOnly is true. 
				Default: 100
			'';
		};
  };

  config = lib.mkIf cfg.enable {
    systemd.services.fw16-kbd-alsd = {
      description = "Framework 16 keyboard backlight auto-control (ALS -> qmk_hid)";
			unitConfig = {
				ConditionPathExists = cfg.alsPath;
			};
      serviceConfig = {
        Type = "oneshot";
        ExecStart = fw16KbdAlsd;
				RuntimeDirectory = "fw16-kbd-alsd";
        ProtectSystem = "strict";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
      };
    };

    systemd.timers.fw16-kbd-alsd = {
      description = "Timer for Framework 16 keyboard backlight auto-control";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5s";
        OnUnitActiveSec = "${toString cfg.pollIntervalSeconds}s";
        Unit = "fw16-kbd-alsd.service";
      };
    };
  };
}
