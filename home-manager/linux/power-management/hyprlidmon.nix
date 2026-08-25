# Hyprland user agent for laptop lid events.
#
# Companion to the lidmond system-module service: lidmond watches the ACPI lid state
# as root and writes event files; this agent reads them inside the Hyprland
# session and acts on them. The split exists because reading /proc/acpi needs
# root while hyprctl needs the user's session — neither side can do both.
#
# The event files are the interface. This module does not talk to lidmond
# directly, so a different producer writing the same format would work.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.hyprlidmon;

  # `or pkgs.hyprland` does NOT help here: finalPackage EXISTS and is null
  # when the preset sets package = null (the system provides the compositor).
  # `or` tests attribute presence, not nullness.
  hyprPkg =
    if config.wayland.windowManager.hyprland.finalPackage != null then
      config.wayland.windowManager.hyprland.finalPackage
    else
      pkgs.hyprland;
  hyprctl = "${hyprPkg}/bin/hyprctl";

  coreutils = "${pkgs.coreutils}/bin";
  jq = "${pkgs.jq}/bin/jq";

  # Shared machine-state detection.
  stateFunctions = # sh
    ''
      STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/hyprlidmon"
      INT_DISP_FILE="$STATE_DIR/int_display"

      ${coreutils}/mkdir -p "$STATE_DIR"

      # Hyprland moved its runtime directory to $XDG_RUNTIME_DIR/hypr; the old
      # /tmp/hypr path finds nothing on current versions.
      if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
      	_hyprdir="''${XDG_RUNTIME_DIR:-/run/user/$(${coreutils}/id -u)}/hypr"
      	if [ -d "$_hyprdir" ]; then
      		_sig="$(${coreutils}/ls -t "$_hyprdir" 2>/dev/null | ${coreutils}/head -n1 || true)"
      		[ -n "''${_sig:-}" ] && export HYPRLAND_INSTANCE_SIGNATURE="''${_sig}"
      	fi
      fi

      # Best-effort internal panel detection, first match wins.
      detect_internal() {
      	_mons="$(${hyprctl} monitors all -j 2>/dev/null)" || return 1

      	# eDP or LVDS prefix covers virtually all internal laptop panels.
      	_int="$(printf '%s' "$_mons" | ${jq} -r '
      		[ .[] | .name ] | map(select(test("^(eDP|LVDS)-"))) | .[0] // empty
      	' 2>/dev/null)" || true
      	[ -n "''${_int:-}" ] && { printf '%s\n' "$_int"; return 0; }

      	# Exactly one DISABLED monitor is probably the internal panel: that is
      	# the state this agent leaves it in while docked.
      	_int="$(printf '%s' "$_mons" | ${jq} -r '
      		[ .[] | select(.disabled == true) | .name ] as $n
      		| if ($n | length) == 1 then $n[0] else empty end
      	' 2>/dev/null)" || true
      	[ -n "''${_int:-}" ] && { printf '%s\n' "$_int"; return 0; }

      	# Exactly one ENABLED monitor and nothing disabled: a laptop with no
      	# external display attached.
      	_int="$(printf '%s' "$_mons" | ${jq} -r '
      		[ .[] | select(.disabled == false) | .name ] as $n
      		| if ($n | length) == 1 then $n[0] else empty end
      	' 2>/dev/null)" || true
      	[ -n "''${_int:-}" ] && { printf '%s\n' "$_int"; return 0; }

      	return 1
      }

      get_internal() {
      	if [ "${cfg.intDisplay}" != "auto" ]; then
      		printf '%s\n' "${cfg.intDisplay}"
      		return 0
      	fi

      	# Trust the cache unconditionally: a disabled panel does not appear in
      	# hyprctl output, so re-detecting while docked would fail and lose the
      	# name needed to re-enable it. The daemon writes this file; the suspend
      	# blocker reads it, which is the main practical gain from merging the
      	# two modules.
      	if [ -r "$INT_DISP_FILE" ]; then
      		_cached="$(${coreutils}/cat "$INT_DISP_FILE" 2>/dev/null || true)"
      		if [ -n "''${_cached:-}" ]; then
      			printf '%s\n' "$_cached"
      			return 0
      		fi
      	fi

      	_det="$(detect_internal 2>/dev/null || true)"
      	if [ -n "''${_det:-}" ]; then
      		printf '%s\n' "$_det" > "$INT_DISP_FILE"
      		printf '%s\n' "$_det"
      		return 0
      	fi

      	return 1
      }

      # Prints connected|none|unknown. "unknown" is distinct from "none": it
      # means the question could not be answered, which a caller may want to
      # treat differently from a confident negative.
      check_external_disp() {
      	if [ -z "''${INT_DISP:-}" ]; then
      		printf 'unknown\n'
      		return 0
      	fi

      	_mons="$(${hyprctl} monitors -j 2>/dev/null)" || { printf 'unknown\n'; return 0; }

      	if printf '%s' "$_mons" | ${jq} -e --arg i "$INT_DISP" \
      		'[ .[] | select(.disabled == false and .name != $i) ] | length > 0' \
      		>/dev/null 2>&1
      	then
      		printf 'connected\n'
      	else
      		printf 'none\n'
      	fi
      }

      # Prints extPower|onBattery|unknown.
      check_power() {
      	for _file in /sys/class/power_supply/*/online; do
      		[ -r "$_file" ] || continue
      		_online="$(${coreutils}/cat "$_file" 2>/dev/null || true)"
      		[ "''${_online:-}" = "1" ] && { printf 'extPower\n'; return 0; }
      	done

      	# A Battery device with no AC online means running on battery. Without
      	# this check a desktop would report onBattery simply for having no
      	# online AC entry.
      	for _type in /sys/class/power_supply/*/type; do
      		[ -r "$_type" ] || continue
      		[ "$(${coreutils}/cat "$_type" 2>/dev/null || true)" = "Battery" ] \
      			&& { printf 'onBattery\n'; return 0; }
      	done

      	printf 'unknown\n'
      }

      # Prints open|closed|unknown.
      check_lid() {
      	for _statef in /proc/acpi/button/lid/*/state; do
      		[ -r "$_statef" ] || continue
      		_state="$(${pkgs.gawk}/bin/awk '{print $2}' "$_statef" 2>/dev/null || true)"
      		case "''${_state:-}" in
      			open|closed) printf '%s\n' "$_state"; return 0 ;;
      		esac
      	done
      	printf 'unknown\n'
      }
    '';

  hyprlidmonWait =
    pkgs.writeShellScriptBin "hyprlidmon-wait" # sh
      ''
        set -eu

        EVENT_DIR=${cfg.eventDir}
        TIMEOUT=${toString cfg.waitTimeoutSeconds}
        INTERVAL=5

        # The event directory only exists if the lidmond system-module service is
        # running.
        _waited=0
        while [ ! -d "$EVENT_DIR" ]; do
        	if [ "$TIMEOUT" -gt 0 ] && [ "$_waited" -ge "$TIMEOUT" ]; then
        		printf "hyprlidmon: %s never appeared after %ss.\n" "$EVENT_DIR" "$TIMEOUT" >&2
        		printf "hyprlidmon: the lidmond SYSTEM service provides it. Enable it with:\n" >&2
        		printf "hyprlidmon:   nixSpace.laptop.lidmond.enable = true;\n" >&2
        		printf "hyprlidmon: if it is enabled, check that its runtime directory matches\n" >&2
        		printf "hyprlidmon: services.hyprlidmon.eventDir (currently %s).\n" "$EVENT_DIR" >&2
        		exit 1
        	fi

        	if [ "$_waited" -gt 0 ] && [ $((_waited % 30)) -eq 0 ]; then
        		printf "hyprlidmon: still waiting for %s (%ss elapsed)\n" "$EVENT_DIR" "$_waited" >&2
        	fi

        	${coreutils}/sleep "$INTERVAL"
        	_waited=$((_waited + INTERVAL))
        done
      '';

  hyprlidmon =
    pkgs.writeShellScriptBin "hyprlidmon" # sh
      ''
        set -eu

        EVENT_DIR=${cfg.eventDir}
        POLL=${toString cfg.pollIntervalSeconds}

        # STATE_DIR, INT_DISP_FILE, the mkdir, and the instance-signature
        # resolution all come from stateFunctions below — they were duplicated
        # here after the merge with hypr-suspend-blocker. Only the files this
        # script alone uses are declared locally.
        #
        # INT_DISP starts EMPTY, not at cfg.intDisplay: the literal string
        # "auto" would pass the `[ -z "$INT_DISP" ]` guards that are supposed
        # to catch an unresolved name, so those checks would silently compare
        # monitor names against "auto".
        INT_DISP=""

        ts=""
        event=""
        lid=""
        extPower=""
        extDisplay=""

        log() {
        	${
           if cfg.logToJournal then
             ''printf "hyprlidmon: %s\n" "$*" >&2''
           else
             # A function body cannot be empty in POSIX sh. The previous
             # version emitted `log() { }` when logging was disabled, which
             # is a parse error.
             ":"
         }
        }

        ${stateFunctions}

        # Declared after stateFunctions because they derive from STATE_DIR,
        # which it sets.
        LAST_FILE="$STATE_DIR/last_seen"
        OPEN_CMDS_FILE="$STATE_DIR/open_cmds"
        INT_DISP_DISABLED_FILE="$STATE_DIR/int_display_disabled"

        [ -e "$OPEN_CMDS_FILE" ] || : > "$OPEN_CMDS_FILE"

        # have_external wraps the shared check_external_disp, which prints
        # connected|none|unknown, into a boolean. "unknown" counts as no
        # external display: acting on a guess here would blank the only
        # working panel.
        have_external() {
        	[ "$(check_external_disp)" = "connected" ]
        }

        # Apply a monitor change and report whether it was applied.
        #
        # `hyprctl keyword` is hyprlang command. Under a Lua config it
        # refuses outright with "keyword can't work with non-legacy parsers"
        # `hyprctl eval` takes a Lua expression instead.
        apply_monitor() {
        	_spec="$1"
        	_out=""
        	_out="$(${hyprctl} eval "$_spec" 2>&1)" || true

        	# Only an explicit "ok" counts.
        	case "''${_out}" in
        		ok*)
        			return 0
        			;;
        		"")
        			log "hyprctl eval returned nothing (compositor unreachable?)"
        			return 1
        			;;
        		*)
        			log "hyprctl eval failed: ''${_out}"
        			return 1
        			;;
        	esac
        }

        disable_internal() {
        	if [ -z "''${INT_DISP:-}" ]; then
        		log "cannot disable internal display: name unknown"
        		return 0
        	fi
        	log "disabling internal display: $INT_DISP"

        	# The flag is written only on success. It records what the display
        	# state actually is, and startup restore reads it to decide whether
        	# to re-apply the disable, because a flag written after a failed call would
        	# make that decision on stale state informatoin.
        	if apply_monitor "hl.monitor({ output = '"$INT_DISP"', disabled = true })"; then
        		${coreutils}/touch "$INT_DISP_DISABLED_FILE"
        	else
        		log "internal display remains enabled"
        	fi
        }

        enable_internal() {
        	if [ -z "''${INT_DISP:-}" ]; then
        		log "cannot enable internal display: name unknown"
        		return 0
        	fi
        	log "enabling internal display: $INT_DISP"

        	# The flag is cleared unconditionally, unlike the disable case.
        	# A stale flag after a failed enable would make startup restore
        	# re-disable a panel the user is trying to get back.
        	apply_monitor "hl.monitor({ output = '"$INT_DISP"', disabled = false })" || true
        	${coreutils}/rm -f "$INT_DISP_DISABLED_FILE"
        }

        run_cmd_list() {
        	for _cmd in "$@"; do
        		[ -n "''${_cmd}" ] || continue

        		case "$_cmd" in
        			--int-display-disable) disable_internal ;;
        			--int-display-enable)  enable_internal ;;
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
        	[ -r "$LAST_FILE" ] && ${coreutils}/cat "$LAST_FILE" || true
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

        	${
           lib.optionalString (cfg.lidClosedDefaultCmd != ":") # sh
             ''log "lidClosed no condition matched; using default" ''
         }

        	run_cmd_list ${lib.escapeShellArg cfg.lidClosedDefaultCmd}
        	return 0
        }

        handle_lidOpened() {
        	# Stored commands first: they encode the decision made at close time,
        	# when the docked state was known.
        	run_stored_open_cmds
        	run_cmd_list ${lib.escapeShellArg cfg.lidOpenedDefaultCmd}
        	return 0
        }

        log "starting; eventDir=$EVENT_DIR poll=$POLL"

        INT_DISP="$(get_internal 2>/dev/null || true)"
        if [ -z "''${INT_DISP:-}" ]; then
        	log "warning: internal display unknown; external detection unreliable."
        fi

        # Restore display state after an agent restart (home-manager rebuild,
        # session restart).
        #
        # If the internal panel was disabled in a previous session, only
        # re-apply that when an external display is still present. Undocking
        # with the lid closed and then restarting would otherwise leave every
        # display off. Run the deferred open command instead the
        # --int-display-enable re-enables the panel and clears the flag.
        if [ -f "$INT_DISP_DISABLED_FILE" ]; then
        	if have_external; then
        		log "startup: external display present — restoring disabled internal display"
        		disable_internal
        	else
        		log "startup: no external display — running deferred open commands"
        		run_stored_open_cmds
        	fi
        fi

        _last="$(last_seen)"

        while true; do
        	if [ ! -d "$EVENT_DIR" ]; then
        		${coreutils}/sleep 1
        		continue
        	fi

        	# Lexicographic order is chronological: event filenames are
        	# timestamp-prefixed.
        	for _file in "$EVENT_DIR"/*.env; do
        		[ -e "$_file" ] || break
        		_base="$(${coreutils}/basename "$_file")"

        		if [ -n "''${_last:-}" ]; then
        			[ "$_base" \> "$_last" ] || continue
        		fi

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

        	${coreutils}/sleep "$POLL"
        done
      '';

  # Suspend blocker: a one-shot command, not a daemon.
  # Bind it in place of `systemctl suspend`.
  hyprSuspendBlocker =
    pkgs.writeShellScriptBin "hypr-suspend-blocker" # sh
      ''
        set -eu

        BLOCKERS_JSON=${lib.escapeShellArg (builtins.toJSON cfg.suspendBlockers)}

        ${stateFunctions}

        state_power=""
        state_lid=""
        state_ext_disp=""
        INT_DISP=""
        do_print=0
        dry_run=0

        # Returns 0 when the named condition holds.
        cond_met() {
        	case "$1" in
        		lidOpen)    [ "$state_lid" = "open" ] ;;
        		lidClosed)  [ "$state_lid" = "closed" ] ;;
        		extPower)   [ "$state_power" = "extPower" ] ;;
        		onBattery)  [ "$state_power" = "onBattery" ] ;;
        		extDisplay) [ "$state_ext_disp" = "connected" ] ;;
        		*)
        			printf 'unknown condition: %s\n' "$1" >&2
        			return 1
        			;;
        	esac
        }

        # Returns 0 when every condition in one list holds.
        #
        list_met() {
        	_list_json="$1"

        	_len="$(printf '%s' "$_list_json" | ${jq} 'length' 2>/dev/null || printf 0)"
        	[ "$_len" -gt 0 ] || return 1

        	_fail=0
        	for _cond in $(printf '%s' "$_list_json" | ${jq} -r '.[]'); do
        		cond_met "$_cond" || _fail=1
        	done

        	[ "$_fail" -eq 0 ]
        }

        # Returns 0 when any list holds.
        any_list_met() {
        	_outer_len="$(printf '%s' "$BLOCKERS_JSON" | ${jq} 'length' 2>/dev/null || printf 0)"
        	[ "$_outer_len" -gt 0 ] || return 1

        	_met=1
        	for _list in $(printf '%s' "$BLOCKERS_JSON" | ${jq} -r '.[] | @base64'); do
        		# base64 so a list survives word-splitting intact.
        		_decoded="$(printf '%s' "$_list" | ${coreutils}/base64 -d)"
        		if list_met "$_decoded"; then
        			_met=0
        		fi
        	done

        	[ "$_met" -eq 0 ]
        }

        print_state() {
        	printf 'power=%s\n' "$state_power"
        	printf 'lid=%s\n' "$state_lid"
        	printf 'extDisplay=%s\n' "$state_ext_disp"
        	printf 'internalDisplay=%s\n' "''${INT_DISP:-unknown}"
        	printf 'blockers=%s\n' "$BLOCKERS_JSON"
        }

        while [ $# -gt 0 ]; do
        	case "$1" in
        		--print)   do_print=1 ;;
        		--dry-run) dry_run=1 ;;
        		"") : ;;
        		*)
        			printf 'invalid argument: %s\n' "$1" >&2
        			exit 2
        			;;
        	esac
        	shift
        done

        state_power="$(check_power)"
        state_lid="$(check_lid)"
        INT_DISP="$(get_internal 2>/dev/null || printf ''')"
        state_ext_disp="$(check_external_disp)"

        if [ "$do_print" -eq 1 ]; then
        	print_state
        	exit 0
        fi

        if any_list_met; then
        	printf 'blocker matched, not suspending\n'
        	print_state
        	exit 0
        fi

        printf 'no blocker matched, suspending\n'
        print_state

        if [ "$dry_run" -eq 1 ]; then
        	exit 0
        fi

        exec ${pkgs.systemd}/bin/systemctl suspend
      '';

  hyprlidmonWrapper =
    pkgs.writeShellScriptBin "hyprlidmon-wrapper" # sh
      ''
        set -eu

        ${hyprlidmonWait}/bin/hyprlidmon-wait

        exec ${hyprlidmon}/bin/hyprlidmon
      '';
in
{
  options.services.hyprlidmon = {
    enable = lib.mkEnableOption "lidmond Hyprland user agent";

    eventDir = lib.mkOption {
      type = lib.types.str;
      default = "/run/lidmond/events";
      description = ''
        Directory holding event files written by the lidmond system service.

        Must match nixSpace.laptop.lidmond's own runtime directory. Nothing
        checks the two agree — a mismatch presents as the agent waiting
        forever with the "still waiting" message.
      '';
    };

    waitTimeoutSeconds = lib.mkOption {
      type = lib.types.int;
      default = 60;
      description = ''
        How long to wait for the lidmond event directory before failing.
        The agent requires it.
      '';
    };

    pollIntervalSeconds = lib.mkOption {
      type = lib.types.number;
      default = 1;
      description = ''
        Interval between event directory scans.

        A poll rather than an inotify watch: the directory may not exist when
        the agent starts, and re-establishing a watch across that is more
        machinery than a one-second sleep is worth.
      '';
    };

    logToJournal = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Emit log lines to the user journal.";
    };

    lidClosedDefaultCmd = lib.mkOption {
      type = lib.types.str;
      default = ":";
      example = "loginctl lock-session";
      description = "Command run on lidClosed when no rule matches.";
    };

    lidOpenedDefaultCmd = lib.mkOption {
      type = lib.types.str;
      default = ":";
      description = ''
        Command run on lidOpened, after any stored open commands.

        Note this is not symmetric with lidClosedDefaultCmd: it runs
        unconditionally rather than only when nothing else did.
      '';
    };

    intDisplay = lib.mkOption {
      type = lib.types.str;
      default = "auto";
      example = "eDP-1";
      description = ''
        Hyprland name of the internal panel, or "auto" to detect it.

        Auto-detection matches an eDP- or LVDS- prefix, then falls back to a
        lone disabled monitor. The result is cached, because a disabled panel
        does not appear in hyprctl output.
      '';
    };

    suspendBlockers = lib.mkOption {
      type = lib.types.listOf (
        lib.types.listOf (
          lib.types.enum [
            "lidOpen"
            "lidClosed"
            "extDisplay"
            "extPower"
            "onBattery"
          ]
        )
      );
      default = [
        [
          "extPower"
        ]
      ];
      example = [
        [ "extPower" ]
        [
          "extDisplay"
          "lidClosed"
        ]
      ];
      description = ''
        Conditions under which `hypr-suspend-blocker` refuses to suspend.

        A list of lists: Every condition within a list must hold for that list
        to match, and suspend is blocked if ANY list matches. So the example
        above blocks on AC power, or when docked with the lid shut.

        An empty list never blocks, so the command is a plain
        `systemctl suspend` passthrough.

        Bind `hypr-suspend-blocker` in place of `systemctl suspend`. It also
        takes --print to dump the detected state and --dry-run to report the
        decision without acting.
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
              description = "Conditions, ANDed together.";
            };
            closeCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Commands run when this rule matches on lidClosed.";
            };
            openCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              description = "Commands stored at close time and run on the next lidOpened.";
            };
          };
        }
      );
      default = [
        {
          cond = [
            "extPower"
            "extDisplay"
          ];
          closeCmd = [ "--int-display-disable" ];
          openCmd = [ "--int-display-enable" ];
        }
      ];
      description = ''
        Rules evaluated on lidClosed, in order. First match wins, so order
        them most specific first.

        openCmd is deferred rather than evaluated at open time because the
        docked state is known at CLOSE — by the time the lid opens, the
        external display may already be gone.

        Two internal switches are recognised alongside shell commands:
          --int-display-disable
          --int-display-enable
      '';
      example = lib.literalExpression ''
        [
          {
            # Docked: on AC with an external display, blank the panel
            cond = [ "extPower" "extDisplay" ];
            closeCmd = [ "loginctl lock-session" "--int-display-disable" ];
            openCmd = [ "--int-display-enable" ];
          }
          {
            # On AC, no external display
            cond = [ "extPower" ];
            closeCmd = [ "loginctl lock-session" ];
          }
        ]
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        # Both in one list can never match, so the list is dead weight that
        # looks meaningful.
        assertion = lib.all (l: !(lib.elem "lidOpen" l && lib.elem "lidClosed" l)) cfg.suspendBlockers;
        message = "services.hyprlidmon.suspendBlockers: a list cannot contain both lidOpen and lidClosed.";
      }
      {
        assertion = lib.all (l: !(lib.elem "extPower" l && lib.elem "onBattery" l)) cfg.suspendBlockers;
        message = "services.hyprlidmon.suspendBlockers: a list cannot contain both extPower and onBattery.";
      }
    ];

    home.packages = [
      hyprlidmon
      hyprlidmonWait
      hyprlidmonWrapper
      hyprSuspendBlocker
    ];

    systemd.user.services.hyprlidmon = {
      Unit = {
        Description = "lidmond Hyprland user agent";
        After = [ "hyprland-session.target" ];
        PartOf = [ "hyprland-session.target" ];

        # Paired with Restart = "on-failure" below: three failures inside ten
        # minutes and systemd stops retrying, leaving the unit in `failed`
        # where a status check will show it.
        StartLimitIntervalSec = 600;
        StartLimitBurst = 3;
      };
      Service = {
        Type = "simple";
        ExecStart = "${hyprlidmonWrapper}/bin/hyprlidmon-wrapper";

        # on-failure with a rate limit, not always/1s.
        #
        # The wrapper now EXITS non-zero when the lidmond event directory
        # never appears. Under Restart = "always" that becomes a restart loop
        # once per second — the unit still looks like it is doing something,
        # which is the failure mode the bounded wait was meant to remove.
        #
        # StartLimit lets systemd give up: after 3 failures in 10 minutes the
        # unit enters `failed` and stays there, so `systemctl --user status`
        # reports the problem instead of an endlessly restarting service.
        Restart = "on-failure";
        RestartSec = 10;

        # PassEnvironment forwards from SYSTEMD's environment, which only has
        # these after Hyprland's start hook runs
        # dbus-update-activation-environment. A service starting before that
        # import gets nothing — which is why the agent also resolves the
        # signature from $XDG_RUNTIME_DIR/hypr itself.
        PassEnvironment = [
          "HYPRLAND_INSTANCE_SIGNATURE"
          "XDG_RUNTIME_DIR"
          "WAYLAND_DISPLAY"
        ];
      };

      # WantedBy hyprland-session.target, not default.target: the agent is
      # useless without a compositor, and PartOf above stops it outliving one.
      Install.WantedBy = [ "hyprland-session.target" ];
    };

    home.activation.restartHyprlidmon = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      if $DRY_RUN_CMD systemctl --user is-active --quiet hyprlidmon 2>/dev/null; then
        $DRY_RUN_CMD systemctl --user restart hyprlidmon
      fi
    '';
  };
}
