# Hyprland user agent that triggers on laptop lid events
# Requires the lidmond system service
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hyprlidmon;

  hyprlidmonWait =
    pkgs.writeShellScriptBin "hyprlidmon-wait" # sh
      ''
        set -eu

        i=0
        printf "hyprlidmon: waiting for lidmond (/run/lidmond/events)...\n" >&2
        while [ ! -d /run/lidmond/events ]; do
        	i=$((i+1))
        	if [ "$i" -eq 6 ]; then
        		printf "hyprlidmon: still waiting. Ensure lidmond service is enabled\n" >&2
        		i=0 # Warn every 30 seconds
        	fi
        	${pkgs.coreutils}/bin/sleep 5
        done
      '';

  hyprlidmon =
    pkgs.writeShellScriptBin "hyprlidmon" # sh
      ''
        set -eu

        EVENT_DIR=${cfg.eventDir}
        POLL=${toString cfg.pollIntervalSeconds}

        STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/hyprlidmon"
        LAST_FILE="$STATE_DIR/last_seen"
        OPEN_CMDS_FILE="$STATE_DIR/open_cmds"

        ${pkgs.coreutils}/bin/mkdir -p "$STATE_DIR"
        [ -e "$OPEN_CMDS_FILE" ] || : > "$OPEN_CMDS_FILE"

        INT_CFG=${cfg.intDisplay}
        INT_DISP_FILE="$STATE_DIR/int_display"
        INT_DISP_DISABLED_FILE="$STATE_DIR/int_display_disabled"
        INT_DISP=${cfg.intDisplay}

        if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        	_sig="$(ls -t /tmp/hypr/ 2>/dev/null | head -n1 || true)"
        	[ -n "''${_sig}" ] && export HYPRLAND_INSTANCE_SIGNATURE="''${_sig}"
        fi

        ts=""
        event=""
        lid=""
        extPower=""
        extDisplay=""

        log() {
        	${lib.optionalString cfg.logToJournal ''
           					printf "hyprlidmon: %s\n" "$*" >&2
         ''}
        }

        # Best-effort to autodetect internal display, first match wins
        detect_internal() {
        	_mons="$(${pkgs.hyprland}/bin/hyprctl monitors all -j 2>/dev/null)" || return 1

        	# Match eDP or LVDS prefix — covers virtually all internal laptop panels
        	_int="$(printf '%s' "$_mons" | ${pkgs.jq}/bin/jq -r '
        			[ .[] | .name ] | map(select(test("^(eDP|LVDS)-"))) | .[0] // empty
        	' 2>/dev/null)" || true
        	[ -n "$_int" ] && printf '%s\n' "$_int" && return 0

        	# If only one enabled monitor exists, assume it's the internal
        	_int="$(printf '%s' "$_mons" \
        			| ${pkgs.jq}/bin/jq -r '
        			[ .[] | select(.disabled == true) | .name ] as $n
        			| if ($n | length) == 1 then $n[0] else empty end
        			' 2>/dev/null)" || true
        	[ -n "$_int" ] && printf '%s\n' "$_int" && return 0

        	return 1
        }

        get_internal() {
        	if [ "$INT_CFG" != "auto" ]; then
        			printf '%s\n' "$INT_CFG"
        			return 0
        	fi

        	# Trust the cache unconditionally — the internal display may be absent
        	# from hyprctl output if currently disabled (e.g. docked with lid closed)
        	if [ -r "$INT_DISP_FILE" ]; then
        			_cached="$(cat "$INT_DISP_FILE" 2>/dev/null || true)"
        			if [ -n "$_cached" ]; then
        					printf '%s\n' "$_cached"
        					return 0
        			fi
        	fi

        	if _det="$(detect_internal 2>/dev/null || true)"; then
        			if [ -n "$_det" ]; then
        					printf '%s\n' "$_det" > "$INT_DISP_FILE"
        					log "auto-detected internal display: $_det"
        					printf '%s\n' "$_det"
        					return 0
        			fi
        	fi

        	log "internal display auto-detect failed. Try manually setting the intDisplay option."
        	return 1
        }

        disable_internal() {
        	log "disabling internal display: $INT_DISP"
        	${pkgs.hyprland}/bin/hyprctl keyword monitor "$INT_DISP,disable" >/dev/null 2>&1 || true
        	touch "$INT_DISP_DISABLED_FILE"
        }

        enable_internal() {
        	log "enabling internal display: $INT_DISP"
        	${pkgs.hyprland}/bin/hyprctl keyword monitor "$INT_DISP,preferred,auto,1" >/dev/null 2>&1 || true
        	rm -f "$INT_DISP_DISABLED_FILE"
        }

        run_cmd_list() {
        	for _cmd in "$@"; do
        		[ -n "''${_cmd}" ] || continue

        		case "$_cmd" in
        			--int-display-disable)
        				disable_internal
        				;;
        			--int-display-enable)
        				enable_internal
        				;;
        			--*)
        				log "unknown internal command: $_cmd"
        				;;
        			*)
        				log "exec: ''${_cmd}"
        				${pkgs.runtimeShell} -c "''${_cmd}" || true
        				;;
        		esac
        	done
        }

        store_open_cmds() {
        	: > "$OPEN_CMDS_FILE"
        	for _cmd in "$@"; do
        		printf '%s\n' "$_cmd" >> "$OPEN_CMDS_FILE"
        	done
        }

        run_stored_open_cmds() {
        	[ -r "$OPEN_CMDS_FILE" ] || return 0
        	while IFS= read -r _cmd; do
        		[ -n "$_cmd" ] || continue
        		run_cmd_list "$_cmd"
        	done < "$OPEN_CMDS_FILE"
        	: > "$OPEN_CMDS_FILE"
        }

        last_seen() {
        	[ -r "$LAST_FILE" ] && cat "$LAST_FILE" || true
        }

        set_last_seen() {
        	printf '%s\n' "$1" > "$LAST_FILE"
        }

        read_event_file() {
        	ts=""; event=""; lid=""; extPower=""
        	# shellcheck disable=SC1090
        	. "$1" 2>/dev/null || true
        	[ -n "$event" ]
        }

        have_external() {
        	if [ -z "''${INT_DISP}" ]; then
        			log "have_external: INT_DISP unknown; assuming no external display"
        			return 1
        	fi
        	_mons="$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null)" || {
        		log "have_external: hyprctl failed (HYPRLAND_INSTANCE_SIGNATURE=''${HYPRLAND_INSTANCE_SIGNATURE:-<unset>})"
        		return 1
        	}
        	printf '%s' "''${_mons}" \
        	| ${pkgs.jq}/bin/jq -e --arg i "''${INT_DISP}" \
        			'map(select(.name != $i and .disabled == false)) | length > 0' \
        	>/dev/null 2>&1 || return 1
        }

        handle_lidClosed() {
        	extDisplay=0
        	if have_external; then
        		extDisplay=1
        	fi
        	log "extDisplay=$extDisplay"

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
                       map (
                         cond:
                         if cond == "extPower" then
                           "[ \"${"$"}{extPower:-0}\" = \"1\" ]"
                         else if cond == "extDisplay" then
                           "[ \"${"$"}{extDisplay:-0}\" = \"1\" ]"
                         else
                           "false"
                       ) conds
                     );

                 closeArgs = lib.concatStringsSep " " (map lib.escapeShellArg closeCmds);
                 openArgs = lib.concatStringsSep " " (map lib.escapeShellArg openCmds);
               in
               # sh
               ''
                 if ${condExpr}; then
                 	log "lidClosed matched cond=${lib.escapeShellArg (builtins.toJSON conds)}"
                 	run_cmd_list ${closeArgs}
                 	store_open_cmds ${openArgs}
                 	return 0
                 fi
               ''
             ) cfg.rules
           )
         }

        	# no rule matched
        	${
           lib.optionalString (cfg.lidClosedDefaultCmd != ":") # sh
             ''log "lidClosed no condition matched; using default" ''
         }

        	run_cmd_list ${lib.escapeShellArg cfg.lidClosedDefaultCmd}
        	return 0
        }

        handle_lidOpened() {
        	# run stored open cmds first (close-time decision)
        	run_stored_open_cmds
        	run_cmd_list ${lib.escapeShellArg cfg.lidOpenedDefaultCmd}
        	return 0
        }

        log "starting; eventDir=$EVENT_DIR poll=$POLL"
        log "scan: eventDir=$EVENT_DIR"
        log "found files: $(ls -1 "$EVENT_DIR"/*.env 2>/dev/null | wc -l)"

        INT_DISP="$(get_internal 2>/dev/null || true)"
        if [ -z "''${INT_DISP}" ]; then
        		log "warning: could not determine internal display; external detection may be unreliable."
        fi

        # Restore display state after restart (e.g. home-manager rebuild)
        if [ -f "$INT_DISP_DISABLED_FILE" ]; then
        		log "startup: restoring disabled internal display"
        		disable_internal
        fi

        _last="$(last_seen)"

        while true; do
        	if [ ! -d "$EVENT_DIR" ]; then
        		${pkgs.coreutils}/bin/sleep 1
        		continue
        	fi

        	# Process events in lexicographic order (timestamp-prefix makes this work)
        	for _file in "$EVENT_DIR"/*.env; do
        		[ -e "$_file" ] || break
        		_base="$(${pkgs.coreutils}/bin/basename "$_file")"

        		# skip if <= last
        		if [ -n "$_last" ]; then
        			[ "$_base" \> "$_last" ] || continue
        		fi

        		log "reading: $_file"
        		if ! read_event_file "$_file"; then
        				log "skipped (invalid/unreadable): $_file"
        				continue
        		fi
        		log "parsed: event=$event extPower=''${extPower:-}"

        		case "$event" in
        				lidClosed) handle_lidClosed ;;
        				lidOpened) handle_lidOpened ;;
        		esac

        		_last="$_base"
        		set_last_seen "$_last"
        	done

        	${pkgs.coreutils}/bin/sleep "$POLL"
        done
      '';

  hyprlidmonWrapper =
    pkgs.writeShellScriptBin "hyprlidmon-wrapper" # sh
      ''
        set -eu

        # Wait for lidmond events dir (print a helpful hint)
        ${hyprlidmonWait}/bin/hyprlidmon-wait

        # Now replace ourselves with the real agent
        exec ${hyprlidmon}/bin/hyprlidmon
      '';
in
{
  options.services.hyprlidmon = {
    enable = lib.mkEnableOption "lidmond user agent";

    eventDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/lidmond/events";
      example = "/run/lidmond/events";
      description = ''
        				Directory containing lidmond event files emitted by the system service.
        				WARNING: This is the default output of lidmond, do not change unless you have also changed lidmond to match.
        			'';
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.number;
      default = 1;
      example = 1;
      description = ''
        				Polling interval (seconds) for reading new events. 
        				Default: 1
        			'';
    };

    logToJournal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      example = true;
      description = ''
        				Enable logging to the user journald.
        				Default: true
        			'';
    };

    lidClosedDefaultCmd = lib.mkOption {
      type = lib.types.str;
      default = ":";
      example = "hyprlock";
      description = ''
        				Command to run on the lidClosed event when no other rules match. 
        				Default: ':'
        			'';
    };

    lidOpenedDefaultCmd = lib.mkOption {
      type = lib.types.str;
      default = ":";
      example = ":";
      description = ''
        				Command to run on the lidOpened event when no other rules match. 
        				Default: ':'
        			'';
    };

    intDisplay = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "eDP-1";
      description = ''
        				Internal panel output name used to detect external monitors. 
        				(Hyprland monitor name). Default: auto";
        			'';
    };

    rules = lib.mkOption {
      type = lib.types.listOf (
        lib.types.submodule {
          options = {
            cond = lib.mkOption {
              type = lib.types.listOf (
                lib.types.enum [
                  "extPower"
                  "extDisplay"
                ]
              );
              default = [ ];
            };
            closeCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
            openCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
            };
          };
        }
      );
      default = [ ];
      description = ''
        				User rules evaluated on lidClosed; first match wins.
        				Service internal switches are provided to disable/enable the internal display with hyprctl:
        					--int-display-disable
        					--int-display-enable

        				Example:
        				[
        					{
        						# Docked mode: on AC + external display → disable internal panel
        						cond = [ "extPower" "extDisplay" ];
        						closeCmd = [ "hyprlock" "--int-display-disable" ];
        						openCmd  = [ "--int-display-enable" ];
        					}
        					{
        						# AC power only, no external display
        						cond = [ "extPower" ];
        						closeCmd = [ "hyprlock" ];
        						openCmd  = [ ":" ];
        					}
        				]
        			'';
      example = lib.literalExpression ''
        				[
        					{
        						# Docked mode: on AC + external display → disable internal panel
        						cond = [ "extPower" "extDisplay" ];
        						closeCmd = [ "hyprlock" "--int-display-disable" ];
        						openCmd  = [ "--int-display-enable" ];
        					}
        					{
        						# AC power only, no external display
        						cond = [ "extPower" ];
        						closeCmd = [ "hyprlock" ];
        						openCmd  = [ ":" ];
        					}
        				]
        			'';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [
      hyprlidmon
      hyprlidmonWait
      hyprlidmonWrapper
    ];

    systemd.user.services."hyprlidmon" = {
      Unit = {
        Description = "lidmond Hyprland user agent";
        After = [ "default.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${hyprlidmonWrapper}/bin/hyprlidmon-wrapper";
        Restart = "always";
        RestartSec = 1;
        PassEnvironment = [
          "HYPRLAND_INSTANCE_SIGNATURE"
          "XDG_RUNTIME_DIR"
          "WAYLAND_DISPLAY"
        ];
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
