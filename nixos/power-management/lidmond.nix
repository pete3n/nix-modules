{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.lidmond;

  backlightDevice = if cfg.backlightDevice == null then "" else cfg.backlightDevice;

  lidmond =
    pkgs.writeShellScriptBin "lidmond" # sh
      ''
        set -eu

				umask 027
				STATE_DIR="/run/lidmond"
				EVENT_DIR="$STATE_DIR/events"
				ACCESS_GROUP=${lib.escapeShellArg cfg.accessGroup}
        DEFAULT_RESTORE_BRIGHTNESS="50"
        BL_DEV=${lib.escapeShellArg backlightDevice}
				OPEN_CMDS_FILE="$STATE_DIR/open_cmds"
				CLOSE_BRIGHTNESS_FILE="$STATE_DIR/close_brightness"

        log() {
        	${lib.optionalString cfg.logToJournal ''
           	printf "lidmond: %s\n" "$*"
          ''
					}
        }

				write_event() {
					_event="$1"

					if check_ext_power; then
						_extPower=1
					else
						_extPower=0
					fi

					_ts="$(${pkgs.coreutils}/bin/date +%Y%m%dT%H%M%S%N)"
					_file="$EVENT_DIR/''${_ts}-''${_event}.env"
					_tmp="$EVENT_DIR/.''${_ts}-''${_event}.env.$$"

					umask 027
					{
						printf 'event=%s\n' "$_event"
						printf 'extPower=%s\n' "''${_extPower:-0}"
						printf 'ts=%s\n' "$_ts"
					} >"$_tmp"

					${pkgs.coreutils}/bin/mv -f "$_tmp" "$_file"
					${pkgs.coreutils}/bin/chown root:"$ACCESS_GROUP" "$_file"
					${pkgs.coreutils}/bin/chmod 0640 "$_file"

					log "wrote event: $_file (extPower=$_extPower)"
				}

        store_open_cmds() {
        	: > "$OPEN_CMDS_FILE"
        	for cmd in "$@"; do
        		printf '%s\n' "$cmd" >> "$OPEN_CMDS_FILE"
        	done
        }

        run_user_cmd() {
        	systemd-run --user --scope ${pkgs.runtimeShell} -c "$1"
        }

        run_stored_open_cmds() {
        	[ -r "$OPEN_CMDS_FILE" ] || return 0
        	while IFS= read -r cmd; do
        		[ -n "$cmd" ] || continue
        		run_cmd_list "$cmd"
        	done < "$OPEN_CMDS_FILE"
        	: > "$OPEN_CMDS_FILE"
        }

        pick_brightnessctl_device() {
        	# Prefer likely internal panel backlights
        	for _bl_dev in amdgpu_bl0 intel_backlight; do
        		if ${pkgs.brightnessctl}/bin/brightnessctl -d "$_bl_dev" g >/dev/null 2>&1; then
        			printf "%s\n" "$_bl_dev"
        			return 0
        		fi
        	done

        	# Fallback: choose the first "backlight" class device that works
        	${pkgs.brightnessctl}/bin/brightnessctl -l 2>/dev/null \
        	| ${pkgs.gawk}/bin/awk -F"'" '/^Device / { print $2 }' \
        		| while IFS= read -r _bl_dev; do
        				[ -n "$_bl_dev" ] || continue
        				if ${pkgs.brightnessctl}/bin/brightnessctl -d "$_bl_dev" g >/dev/null 2>&1; then
        					printf "%s\n" "$_bl_dev"
        					return 0
        				fi
        			done

        	return 1
        }

        ensure_bl_dev() {
        	if [ -z "$BL_DEV" ]; then
        		BL_DEV="$(pick_brightnessctl_device 2>/dev/null || true)"
        	fi
        }

        record_close_brightness() {
        	ensure_bl_dev

        	if [ -n "$BL_DEV" ]; then
        		_cur="$(${pkgs.brightnessctl}/bin/brightnessctl -d "$BL_DEV" g 2>/dev/null || true)"
        	else
        		_cur="$(${pkgs.brightnessctl}/bin/brightnessctl g 2>/dev/null || true)"
        	fi

        	case "$_cur" in
        		""|*[!0-9]*) return 1 ;;
        		*) printf '%s\n' "$_cur" > "$CLOSE_BRIGHTNESS_FILE"; return 0 ;;
        	esac
        }

        backlight_off() {
        	if record_close_brightness; then
        		log "recorded close brightness: $(${pkgs.coreutils}/bin/cat "$CLOSE_BRIGHTNESS_FILE" 2>/dev/null || printf "?\n")"
        	else
        		log "could not record close brightness; will restore default ''${DEFAULT_RESTORE_BRIGHTNESS}"
        		: > "$CLOSE_BRIGHTNESS_FILE" 2>/dev/null || true
        	fi

        	ensure_bl_dev

        	if [ -n "$BL_DEV" ]; then
        		${pkgs.brightnessctl}/bin/brightnessctl -d "$BL_DEV" set 0 2>/dev/null \
        			|| ${pkgs.brightnessctl}/bin/brightnessctl -d "$BL_DEV" set 1 2>/dev/null \
        			|| true
        	else
        		${pkgs.brightnessctl}/bin/brightnessctl set 0 2>/dev/null \
        			|| ${pkgs.brightnessctl}/bin/brightnessctl set 1 2>/dev/null \
        			|| true
        	fi
        }

        backlight_on() {
        	ensure_bl_dev

        	_restore=""
        	if [ -r "$CLOSE_BRIGHTNESS_FILE" ]; then
        		_restore="$(${pkgs.coreutils}/bin/cat "$CLOSE_BRIGHTNESS_FILE" 2>/dev/null || true)"
        	fi

        	case "$_restore" in
        		""|*[!0-9]*)
        			_restore="$DEFAULT_RESTORE_BRIGHTNESS"
        			log "restore brightness missing/invalid; using default ''${DEFAULT_RESTORE_BRIGHTNESS}"
        			;;
        		*)
        			log "restoring brightness to ''${_restore}"
        			;;
        	esac

        	if [ -n "$BL_DEV" ]; then
        		${pkgs.brightnessctl}/bin/brightnessctl -d "$BL_DEV" set "$_restore" 2>/dev/null \
        			|| ${pkgs.brightnessctl}/bin/brightnessctl -d "$BL_DEV" set "$DEFAULT_RESTORE_BRIGHTNESS" 2>/dev/null \
        			|| true
        	else
        		${pkgs.brightnessctl}/bin/brightnessctl set "$_restore" 2>/dev/null \
        			|| ${pkgs.brightnessctl}/bin/brightnessctl set "$DEFAULT_RESTORE_BRIGHTNESS" 2>/dev/null \
        			|| true
        	fi

        	: > "$CLOSE_BRIGHTNESS_FILE" 2>/dev/null || true
        }

        check_lid() {
        	for _statef in /proc/acpi/button/lid/*/state; do
        		[ -r "$_statef" ] || continue
        		_state="$(${pkgs.gawk}/bin/awk '{print $2}' "$_statef" 2>/dev/null || true)"
        		case "$_state" in
        			open|closed) printf '%s\n' "$_state"; return 0 ;;
        		esac
        	done
        	printf "unknown\n"
        }

        check_ext_power() {
        	# extPower=true if any /sys/class/power_supply/*/online is "1"
        	_ac_online=0
        	for file in /sys/class/power_supply/*/online; do
        		[ -r "$file" ] || continue
        		if [ "$(${pkgs.coreutils}/bin/cat "$file" 2>/dev/null || echo 0)" = "1" ]; then
        			_ac_online=1
        			break
        		fi
        	done
        	[ "$_ac_online" = "1" ]
        }

        run_cmd_list() {
        	for _cmd in "$@"; do
        		[ -n "''${_cmd}" ] || continue

        		HYPR_LMD_CLOSE_BRIGHTNESS=""
        		if [ -r "$CLOSE_BRIGHTNESS_FILE" ]; then
        			HYPR_LMD_CLOSE_BRIGHTNESS="$(cat "$CLOSE_BRIGHTNESS_FILE" 2>/dev/null || true)"
        		fi
        		export HYPR_LMD_CLOSE_BRIGHTNESS
        		log "HYPR_LMD_CLOSE_BRIGHTNESS=''${HYPR_LMD_CLOSE_BRIGHTNESS}"

        		log "exec: ''${_cmd}"
        		${pkgs.runtimeShell} -c "''${_cmd}" || true
        	done
        }

        # Evaluate lidClosed rules: first match wins; else default lidClosedDefaultCmd
        handle_lidClosed() {
        	${
           lib.concatStringsSep "\n" (
             map (
               rule:
               let
                 conds = rule.cond or [ ];
                 closeCmds = rule.closeCmd or [ ];
                 openCmds = rule.openCmd or [ ];
                 condExpr =
                   if conds == [ ] then
                     "true"
                   else
                     lib.concatStringsSep " && " (
                       map (con: if con == "extPower" then "check_ext_power" else "false") conds
                     );
                 closeArgs = lib.concatStringsSep " " (map lib.escapeShellArg closeCmds);
                 openArgs = lib.concatStringsSep " " (map lib.escapeShellArg openCmds);
               in
               # sh
               ''
                 if ${condExpr}; then
                 log "lidClosed matched cond=${lib.escapeShellArg (builtins.toJSON conds)}"
                 run_cmd_list ${closeArgs}
                 store_open_cmds ${openArgs} # Save state for when the lid is opened
                 return 0
                 fi
               ''
             ) cfg.rules
           )
         }
        	log "lidClosed no condition matched; using default"
        	run_cmd_list ${lib.escapeShellArg cfg.lidClosedDefaultCmd}
        }

        handle_lidOpened() {
        	run_stored_open_cmds
        	run_cmd_list ${lib.escapeShellArg cfg.lidOpenedDefaultCmd}
        }

        log "starting (pollInterval=${toString cfg.pollIntervalSeconds}s)"
        _last="$(check_lid)"

        case "''${1:-}" in
        	--backlight-off) backlight_off; exit 0 ;;
        	--backlight-on)  backlight_on;  exit 0 ;;
        	""|daemon) : ;;
        	*)
        		printf "usage: lidmond [daemon|--backlight-off|--backlight-on]\n" >&2
        		exit 2
        		;;
        esac

        while true; do
        	_now="$(check_lid)"
        	[ "$_now" = "unknown" ] && ${pkgs.coreutils}/bin/sleep 0.1 && continue
        	if [ "$_now" != "$_last" ]; then
        		log "lid state changed: $_last -> $_now"
        		case "$_now" in
        			closed) 
								write_event lidClosed
								handle_lidClosed 
								;;
        			open)   
								write_event lidOpened
								handle_lidOpened ;;
        			*) log "failed to read lid state" ;;
        		esac
        		_last="$_now"
        	fi
        	${pkgs.coreutils}/bin/sleep ${toString cfg.pollIntervalSeconds}
        done
      '';
in
{
  options.services.lidmond = {
    enable = lib.mkEnableOption "lidmond lid event handler";

    accessGroup = lib.mkOption {
      type = lib.types.str;
      default = "lidmond";
			example = "wheel";
			description = ''
				Group granted read access to lidmond state and events under /run/lidmond.

				lidmond writes event files to:
					/run/lidmond/events

				Users in this group can read those event files (e.g., for hyprlidmon).
			'';
    };

    # triggers
    lidClosedDefaultCmd = lib.mkOption {
      type = lib.types.str;
      default = "systemctl suspend";
      example = "systemctl suspend";
      description = ''
				Command to run on lidClosed if no other rule matches. 
				Default: systemctl suspend
			'';
    };

    lidOpenedDefaultCmd = lib.mkOption {
      type = lib.types.str;
      default = ":";
      description = ''
				Command to run on lidOpenened if no other rule matches. 
				Default: systemctl suspend
			'';
    };

    rules = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            cond = lib.mkOption {
              type = lib.types.listOf (lib.types.enum [ "extPower" ]);
              default = [ ];
							example = [ "extPower" ];
							description = "Condition list. Currently supports: extPower.";
            };
            closeCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
							example = [ "lidmond --backlight-off" ];
							description = "Commands to run when lidClosed and this rule matches.";
            };
            openCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
							example = [ "lidmond --backlight-on" ];
							description = "Commands to run when lidOpened (for this rule) after a matching close.";
            };
          };
        }
      );

      default = [
        {
          cond = [ "extPower" ];
          closeCmd = [ "lidmond --backlight-off" ];
          openCmd = [ "lidmond --backlight-on" ];
        }
      ];

			example = lib.literalExpression ''
				[
					{
						# On AC power: turn backlight off when lid closes, restore on open
						cond = [ "extPower" ];
						closeCmd = [ "lidmond --backlight-off" ];
						openCmd  = [ "lidmond --backlight-on" ];
					}
				]
			'';

			description = ''
				Rule list evaluated on lidClosed, in order. First match wins.

				Conditions:
					- "extPower": external power is online (any /sys/class/power_supply/*/online == 1)

				lidmond always writes event files to /run/lidmond/events; rules control
				additional actions (like backlight control).

				Example:
					[
						{
							# On AC power: turn backlight off when lid closes, restore on open
							cond = [ "extPower" ];
							closeCmd = [ "lidmond --backlight-off" ];
							openCmd  = [ "lidmond --backlight-on" ];
						}
					]
			'';
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.number;
      default = 1;
			example = 1;
      description = ''
				Polling interval (in seconds) to check lid state. 
				Default: 1
			'';
    };

    logToJournal = lib.mkOption {
      type = lib.types.bool;
      default = true;
			example = true;
      description = ''
				Whether to emit log lines to journald. 
				Default: true
			'';
    };

    backlightDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
			example = "nvidia_wmi_ec_backlight";
      description = ''
				brightnessctl device name to control (e.g., amdgpu_bl0). 
				If null, auto-detect. 
				Default: null
			'';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion =
          let
            login = config.services.logind.settings.Login or { };
            logindHls = login.HandleLidSwitch or null;
            logindHlsd = login.HandleLidSwitchDocked or null;
            logindHlsep = login.HandleLidSwitchExternalPower or null;
          in
          logindHls == "ignore" && logindHlsd == "ignore" && logindHlsep == "ignore";
        message = ''
          services.lidmond is enabled, but systemd-logind is still configured to handle lid events.

          To avoid race conditions, set:

          services.logind.settings.Login.HandleLidSwitch = "ignore";
          services.logind.settings.Login.HandleLidSwitchDocked = "ignore";
          services.logind.settings.Login.HandleLidSwitchExternalPower = "ignore";

          (Or disable services.lidmond.)
        '';
      }
    ];

		users.groups = lib.mkIf (cfg.accessGroup == "lidmond") {
			lidmond = {};
		};

		systemd.tmpfiles.rules = [
			"d /run/lidmond 0750 root ${cfg.accessGroup} -"
			"d /run/lidmond/events 2750 root ${cfg.accessGroup} -"
		];

    systemd.services."lidmond" = {
      description = "Hypr lid monitor (custom lid event handler)";
      wantedBy = [ "multi-user.target" ];
      after = [ "multi-user.target" ];
      path = [ lidmond ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${lidmond}/bin/lidmond";
        Restart = "always";
        RestartSec = 1;
				UMask = "0027"; # Mask for group rx, owner rwx
				RuntimeDirectory = "lidmond lidmond/events"; 
				RuntimeDirectoryMode = "2750"; # Inherit group from parent directory
				Group = cfg.accessGroup;
				NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [
          "/run/lidmond"
          "/sys/class/backlight"
        ];
        ReadOnlyPaths = [
          "/proc/acpi"
          "/sys/class/power_supply"
        ];
      };
    };
  };
}
