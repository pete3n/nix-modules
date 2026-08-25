# Hyprland user agent for laptop lid events.
#
# Companion to the lidmond SYSTEM service: lidmond watches the ACPI lid state
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

  # hyprctl must come from the compositor that is RUNNING, not from whichever
  # Hyprland nixpkgs happens to package. The previous version used
  # pkgs.hyprland unconditionally — with a pinned or overlaid compositor those
  # differ, and version-skewed hyprctl against a live instance fails in ways
  # that read as the socket being wrong.
  hyprPkg = config.wayland.windowManager.hyprland.finalPackage or pkgs.hyprland;
  hyprctl = "${hyprPkg}/bin/hyprctl";

  coreutils = "${pkgs.coreutils}/bin";
  jq = "${pkgs.jq}/bin/jq";

  hyprlidmonWait =
    pkgs.writeShellScriptBin "hyprlidmon-wait" # sh
      ''
        set -eu

        i=0
        printf "hyprlidmon: waiting for lidmond (${cfg.eventDir})...\n" >&2
        while [ ! -d ${cfg.eventDir} ]; do
        	i=$((i+1))
        	if [ "$i" -eq 6 ]; then
        		printf "hyprlidmon: still waiting. Ensure the lidmond system service is enabled\n" >&2
        		i=0 # Warn every 30 seconds
        	fi
        	${coreutils}/sleep 5
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

        ${coreutils}/mkdir -p "$STATE_DIR"
        [ -e "$OPEN_CMDS_FILE" ] || : > "$OPEN_CMDS_FILE"

        INT_CFG=${cfg.intDisplay}
        INT_DISP_FILE="$STATE_DIR/int_display"
        INT_DISP_DISABLED_FILE="$STATE_DIR/int_display_disabled"

        # Empty until get_internal resolves it below. The previous version
        # initialised this to cfg.intDisplay, so before resolution it held the
        # literal string "auto" — and have_external's `[ -z "$INT_DISP" ]`
        # guard does not catch that, so a reordering would have compared
        # monitor names against "auto" instead of failing cleanly.
        INT_DISP=""

        # Hyprland moved its runtime directory to $XDG_RUNTIME_DIR/hypr; the
        # old /tmp/hypr path finds nothing on current versions.
        if [ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
        	_hyprdir="''${XDG_RUNTIME_DIR:-/run/user/$(${coreutils}/id -u)}/hypr"
        	if [ -d "$_hyprdir" ]; then
        		_sig="$(${coreutils}/ls -t "$_hyprdir" 2>/dev/null | ${coreutils}/head -n1 || true)"
        		[ -n "''${_sig:-}" ] && export HYPRLAND_INSTANCE_SIGNATURE="''${_sig}"
        	fi
        fi

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
               # is a parse error — the agent failed to start at all.
               ":"
           }
        }

        # Best-effort internal panel detection, first match wins.
        detect_internal() {
        	_mons="$(${hyprctl} monitors all -j 2>/dev/null)" || return 1

        	# eDP or LVDS prefix covers virtually all internal laptop panels.
        	_int="$(printf '%s' "$_mons" | ${jq} -r '
        			[ .[] | .name ] | map(select(test("^(eDP|LVDS)-"))) | .[0] // empty
        	' 2>/dev/null)" || true
        	[ -n "''${_int:-}" ] && printf '%s\n' "$_int" && return 0

        	# Fallback: exactly one DISABLED monitor is probably the internal
        	# panel, since that is the state this agent leaves it in when docked.
        	_int="$(printf '%s' "$_mons" \
        			| ${jq} -r '
        			[ .[] | select(.disabled == true) | .name ] as $n
        			| if ($n | length) == 1 then $n[0] else empty end
        			' 2>/dev/null)" || true
        	[ -n "''${_int:-}" ] && printf '%s\n' "$_int" && return 0

        	return 1
        }

        get_internal() {
        	if [ "$INT_CFG" != "auto" ]; then
        		printf '%s\n' "$INT_CFG"
        		return 0
        	fi

        	# Trust the cache unconditionally: the internal panel may be ABSENT
        	# from hyprctl output while disabled (docked, lid closed), so
        	# re-detecting at that moment would fail and lose the name needed to
        	# re-enable it.
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
        		log "auto-detected internal display: $_det"
        		printf '%s\n' "$_det"
        		return 0
        	fi

        	log "internal display auto-detect failed. Set the intDisplay option manually."
        	return 1
        }

        # Apply a monitor change and report whether it took.
        #
        # `hyprctl keyword` is LEGACY-PARSER ONLY. Under a Lua config it
        # refuses outright with "keyword can't work with non-legacy parsers"
        # — and the previous version discarded that message with
        # `>/dev/null 2>&1 || true`, then wrote the state flag anyway. The
        # disable silently never happened while the flag claimed it had, so
        # the startup restore logic acted on a lie.
        #
        # `hyprctl eval` takes a Lua expression instead.
        #
        # ON `set -e`: the assignment is its own statement and the `|| true`
        # keeps a non-zero hyprctl exit from killing the agent. Do NOT fold
        # this into `if _out="$(...)"; then` — a command substitution failing
        # inside a condition is fine, but the pattern invites someone to drop
        # the guard later. The exit status is deliberately ignored in favour
        # of inspecting the OUTPUT, because hyprctl exits 0 while printing an
        # error for at least this case.
        apply_monitor() {
        	_spec="$1"
        	_out=""
        	_out="$(${hyprctl} eval "$_spec" 2>&1)" || true

        	# Only an explicit "ok" counts. Empty output was previously treated
        	# as success too, which would mask a spec that parsed but did
        	# nothing — the exact failure this function exists to surface.
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

        	# The flag is written ONLY on success. It records what the display
        	# state actually is, and startup restore reads it to decide whether
        	# to re-apply the disable — a flag written after a failed call would
        	# make that decision on false information.
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

        	# The flag is cleared UNCONDITIONALLY, unlike the disable case.
        	# A stale flag after a failed enable would make startup restore
        	# re-disable a panel the user is trying to get back — the failure
        	# mode of clearing it wrongly is a redundant enable attempt, which
        	# is harmless.
        	#
        	# `disabled = false` explicitly, mirroring the disable call. A
        	# monitor spec MERGES rather than replacing, so omitting the field
        	# leaves the panel disabled — the previous form set mode, position
        	# and scale, reported "ok", and changed nothing visible.
        	#
        	# Restating mode/position/scale would also override whatever the
        	# user declared for this output in their monitor settings. Toggling
        	# only the field this module owns leaves the rest intact.
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

        have_external() {
        	if [ -z "''${INT_DISP:-}" ]; then
        		log "have_external: internal display unknown; assuming none"
        		return 1
        	fi
        	_mons="$(${hyprctl} monitors -j 2>/dev/null)" || {
        		log "have_external: hyprctl failed (HYPRLAND_INSTANCE_SIGNATURE=''${HYPRLAND_INSTANCE_SIGNATURE:-<unset>})"
        		return 1
        	}
        	printf '%s' "''${_mons}" \
        		| ${jq} -e --arg i "''${INT_DISP}" \
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
        # display off — instead run the deferred open commands, whose stored
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
        Command run on lidOpened, AFTER any stored open commands.

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
        does not appear in hyprctl output — without the cache, the name needed
        to re-enable it would be unavailable exactly when it is needed.
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
              description = "Conditions, ANDed together.";
            };
            closeCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Commands run when this rule matches on lidClosed.";
            };
            openCmd = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = "Commands stored at close time and run on the next lidOpened.";
            };
          };
        }
      );
      default = [ ];
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
    home.packages = [
      hyprlidmon
      hyprlidmonWait
      hyprlidmonWrapper
    ];

    systemd.user.services.hyprlidmon = {
      Unit = {
        Description = "lidmond Hyprland user agent";
        After = [ "hyprland-session.target" ];
        PartOf = [ "hyprland-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = "${hyprlidmonWrapper}/bin/hyprlidmon-wrapper";
        Restart = "always";
        RestartSec = 1;

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
