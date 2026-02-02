# batmond a battery monitoring systemd user daemon
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

  cfg = config.services.batmond;

  batmond =
    pkgs.writeShellScriptBin "batmond" # sh
      ''
				set -eu 

				GUI_NOTIFY_CMD="${toString cfg.guiNotifyCmd}"
				TTY_NOTIFY_CMD="${toString cfg.ttyNotifyCmd}"
				WARN_BELOW_PERCENT="${toString cfg.warnBelowPercent}"
				WARN_BELOW_GUI_MSG="${cfg.warnBelowGuiMsg}"
				WARN_BELOW_TTY_MSG="${cfg.warnBelowTtyMsg}"
				SUSPEND_PERCENT="${toString cfg.suspendPercent}"
				SUSPEND_GUI_MSG="${cfg.suspendGuiMsg}"
				SUSPEND_TTY_MSG="${cfg.suspendTtyMsg}"
				SUSPEND_SUB_CMD="${toString cfg.suspendSubCmd}"
				HIBERNATE_PERCENT="${toString cfg.hibernatePercent}"
				HIBERNATE_GUI_MSG="${cfg.hibernateGuiMsg}"
				HIBERNATE_TTY_MSG="${cfg.hibernateTtyMsg}"
				HIBERNATE_SUB_CMD="${toString cfg.hibernateSubCmd}"
				SHUTDOWN_PERCENT="${toString cfg.shutdownPercent}"
				SHUTDOWN_GUI_MSG="${cfg.shutdownGuiMsg}"
				SHUTDOWN_TTY_MSG="${cfg.shutdownTtyMsg}"
				SHUTDOWN_SUB_CMD="${toString cfg.shutdownSubCmd}"
				STATE_DIR="''${XDG_STATE_HOME:-$HOME/.local/state}/batmond"
				STATE_FILE="''${STATE_DIR}/bat_last_cap"
				mkdir -p "''${STATE_DIR}" 

				bat_path=""
				bat_status=""
				bat_cap="100" # Assume full until measured
				bat_last_cap="101" # 101 means unmeasured

				log() {
					${lib.optionalString cfg.logEvents #sh 
					''
						_event="$1"; _cap="$2"; _th="$3"; _cmd="$4"
						${pkgs.util-linux}/bin/logger -t batmond -- "event=$_event cap=''${_cap}% threshold=''${_th}% cmd=$_cmd"
					''}

					# Logging disabled
					${lib.optionalString (!cfg.logEvents) #sh 
						'' : ''
					}
				}

				notify_tty() {
					_title="$1"
					_body="$2"
					printf '%s - %s\n' "$_title" "$_body" \
					| ${pkgs.runtimeShell} -c "$TTY_NOTIFY_CMD" >/dev/null 2>&1 || true
				}

				notify_gui() {
					_title="$1"
					_body="$2"
					${pkgs.runtimeShell} -c "$GUI_NOTIFY_CMD \"$_title\" \"$_body\"" >/dev/null 2>&1
				}

				notify() {
					_title="$1"
					_gui_msg="$2"
					_tty_msg="$3"
					notify_gui "$_title" "$_gui_msg"
					notify_tty "$_title" "$_tty_msg"
				}

				update_bat_last_cap() {
					printf "%s\n" "''${bat_cap}" > "''${STATE_FILE}"
				}

				for _dir in /sys/class/power_supply/*; do
					[ -r "$_dir/type" ] || continue
					[ "$(${pkgs.coreutils}/bin/cat "$_dir/type" 2>/dev/null || true)" = "Battery" ] || continue
					bat_path="$_dir"
					break
				done
				[ -n "$bat_path" ] || exit 0

				bat_status="$(${pkgs.coreutils}/bin/cat "''${bat_path}/status" 2>/dev/null || printf "Unknown")"
				bat_cap="$(${pkgs.coreutils}/bin/cat "''${bat_path}/capacity" 2>/dev/null || printf "100")"
				case "$bat_cap" in
					""|*[!0-9]*) bat_cap=100 ;;
				esac

				# Load last seen percentage (101 = "not seen discharging")
				if [ -f "''${STATE_FILE}" ]; then
					read -r bat_last_cap < "''${STATE_FILE}" || bat_last_cap="101"
				fi
				
				# If not discharging, reset state and exit
				case "$bat_status" in
					Discharging) : ;;
					Charging|Full) printf "101\n" > "$STATE_FILE"; exit 0 ;;
					*) exit 0 ;; # Unknown / Not charging
				esac

				# Check in reverse order from shutdown to hibernate to suspend to warn
				if [ "''${SHUTDOWN_PERCENT}" -gt 0 ] && [ "''${bat_cap}" -le "''${SHUTDOWN_PERCENT}" ] \
				&& [ "''${bat_last_cap}" -gt "''${SHUTDOWN_PERCENT}" ]; then
					update_bat_last_cap
					notify "Battery ''${bat_cap}%" "$SHUTDOWN_GUI_MSG" "$SHUTDOWN_TTY_MSG"
					log "shutdown" "$bat_cap" "$SHUTDOWN_PERCENT" "systemctl $SHUTDOWN_SUB_CMD"
					${pkgs.systemd}/bin/systemctl "$SHUTDOWN_SUB_CMD"
					exit 0
				fi

				if [ "''${HIBERNATE_PERCENT}" -gt 0 ] && [ "''${bat_cap}" -le "''${HIBERNATE_PERCENT}" ] \
				&& [ "''${bat_last_cap}" -gt "''${HIBERNATE_PERCENT}" ]; then
					update_bat_last_cap
					notify "Battery ''${bat_cap}%" "$HIBERNATE_GUI_MSG" "$HIBERNATE_TTY_MSG"
					log "hibernate" "$bat_cap" "$HIBERNATE_PERCENT" "systemctl $HIBERNATE_SUB_CMD"
					${pkgs.systemd}/bin/systemctl "$HIBERNATE_SUB_CMD"
					exit 0
				fi

				if [ "''${SUSPEND_PERCENT}" -gt 0 ] && [ "''${bat_cap}" -le "''${SUSPEND_PERCENT}" ] \
				&& [ "''${bat_last_cap}" -gt "''${SUSPEND_PERCENT}" ]; then
					update_bat_last_cap
					notify "Battery ''${bat_cap}%" "$SUSPEND_GUI_MSG" "$SUSPEND_TTY_MSG"
					log "suspend" "$bat_cap" "$SUSPEND_PERCENT" "systemctl $SUSPEND_SUB_CMD"
					${pkgs.systemd}/bin/systemctl "$SUSPEND_SUB_CMD"
					exit 0
				fi

				if [ "''${WARN_BELOW_PERCENT}" -gt 0 ] && [ "''${bat_cap}" -lt "''${WARN_BELOW_PERCENT}" ] \
				&& [ "''${bat_cap}" -lt "''${bat_last_cap}" ]; then
					update_bat_last_cap
					notify "Battery ''${bat_cap}%" "$WARN_BELOW_GUI_MSG" "$WARN_BELOW_TTY_MSG"
					log "warn" "$bat_cap" "$WARN_BELOW_PERCENT" "none"
					exit 0
				fi
      '';
in
{
  options.services.batmond = {
    enable = mkEnableOption "Battery monitering service with warning + suspend/hibernate/shutdown actions";

		logEvents = mkOption {
			type = types.bool;
			default = true;
			description = ''
				Whether to log events with logger -t batmond

				Default: true
			'';
		};

		guiNotifyCmd = mkOption {
			type = types.str;
			default = "${pkgs.libnotify}/bin/notify-send -u critical";
			description = ''
				Command used for GUI notifications.
				It will be executed as:
					$GUI_NOTIFY_CMD "Battery %" "$notifyMsg"

				Default: '${pkgs.libnotify}/bin/notify-send -u critical'
			'';
		};

		ttyNotifyCmd = mkOption {
			type = types.str;
			default = "${pkgs.util-linux}/bin/wall -n";
			description = ''
				Command used for non-GUI notifications.
				Message will be passed on stdin.
				Set to ':' to disable.

				Default: '${pkgs.util-linux}/bin/wall -n'
			'';
		};

    warnBelowPercent = mkOption {
      type = types.ints.between 0 100;
      default = 15;
      description = ''
				Battery percentage at or below continuos warnings are given.
				Set to 0 to disable repeat warnings. 

				Default: 15
			'';
    };

    warnBelowGuiMsg = mkOption {
      type = types.str;
      default = "🪫‼️ Warning battery is running low!";
      description = ''
				Notification message to display for repeated battery warnings in a graphical environemnt 
				when the battery is below the warnBelowPercent level.

				Default: '🪫‼️ Warning battery is running low!'
			'';
    };

    warnBelowTtyMsg = mkOption {
      type = types.str;
      default = "!! Warning battery is running low!";
      description = ''
				Notification message to display for repeated battery warnings in a TTY environemnt 
				when the battery is below the warnBelowPercent level.
				
				Default: 'Battery low. Suspending system...'
			'';
    };

    suspendPercent = mkOption {
      type = types.ints.between 0 100;
      default = 10;
      description = ''
				Battery percentage at or below which the system will suspend.
				Triggers once per discharge cycle when crossing this threshold.
				Set to 0 to disable suspend. 

				Default: 10
			'';
    };

		suspendSubCmd = mkOption {
			type = types.enum [ "suspend" "hibernate" "hybrid-sleep" "suspend-then-hibernate" ];
			default = "suspend";
			description = ''
				systemctl sub-command to execute when suspendPercent is triggered.
				Must be one of: suspend hibernate hybrid-sleep suspend-then-hibernate

				Default: suspend
			'';
		};

    suspendTtyMsg = mkOption {
      type = types.str;
      default = "Battery low. Suspending system...";
      description = ''
				Notification shown when suspending system in a TTY environment.
				
				Default: 'Battery low. Suspending system...'
			'';
    };

    suspendGuiMsg = mkOption {
      type = types.str;
      default = "🪫‼️ Batter low. 🌙 Suspending system...";
      description = ''
				Notification shown when suspending system in a graphical environment.
				
				Default: '🪫‼️ Batter low. 🌙 Suspending system...'
			'';
    };

    hibernatePercent = mkOption {
      type = types.ints.between 0 100;
      default = 0;
      description = ''
				Battery percentage at or below which the system will hibernate.
				Triggers once per discharge cycle when crossing this threshold.
				Set to 0 to disable hibernate.
				NOTE: You must have swap+resume correctly configured for this to function.

				Default: 0
			'';
    };

		hibernateSubCmd = mkOption {
			type = types.enum [ "suspend" "hibernate" "hybrid-sleep" "suspend-then-hibernate" ];
			default = "hibernate";
			description = ''
				systemctl sub-command to execute when hibernatePercent is triggered.
				Must be one of: suspend hibernate hybrid-sleep suspend-then-hibernate

				Default: hibernate
			'';
		};

    hibernateTtyMsg = mkOption {
      type = types.str;
      default = "Battery severely low. Hibernating system...";
      description = ''
				Notification shown when suspending system in a TTY environment.
				
				Default: 'Battery severely low. Hibernating system...'
			'';
    };

    hibernateGuiMsg = mkOption {
      type = types.str;
      default = "🪫‼️ Batter severely low.  Hibernating system...";
      description = ''
				Notification shown when hibernating system in a graphical environment.

				Default: '🪫‼️ Batteryseverely low.  Hibernating system...'
			'';
    };

    shutdownPercent = mkOption {
      type = types.ints.between 0 100;
      default = 1;
      description = ''
				Battery percentage at which the system will shutdown.
				Triggers once per discharge cycle when crossing this threshold.
				Set to 0 to disable shutdown. 

				Default: 1
			'';
    };

		shutdownSubCmd = mkOption {
			type = types.enum [ "suspend" "hibernate" "hybrid-sleep" "suspend-then-hibernate" "poweroff" ];
			default = "poweroff";
			description = ''
				systemctl sub-command to execute when shutdownPercent is triggered.
				Must be one of: suspend hibernate hybrid-sleep suspend-then-hibernate poweroff

				Default: poweroff
			'';
		};

    shutdownGuiMsg = mkOption {
      type = types.str;
      default = "🪫‼️ Battery critically low. ⏻ Shutting down...";
      description = ''
				Notification shown when shutting down the system in a graphical environment.

				Default: '🪫‼️ Battery critically low. ⏻ Shutting down...'
			'';
    };

    shutdownTtyMsg = mkOption {
      type = types.str;
      default = "Battery critically low. Shutting down system...";
      description = ''
				Notification shown when shutting down the system in a TTY environment.
				
				Default: 'Battery critically low. Shutting down system...'
			'';
    };

    batteryInterval = mkOption {
      type = types.ints.positive;
      default = 30;
      description = "How often (in seconds) to check the battery bat_status.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = [
      batmond
    ];

		systemd.user.services."batmond" = {
			Unit = {
				Description = "Battery level warning notifications and actions";
			};

			Service = {
				Type = "oneshot";
				ExecStart = "${batmond}/bin/batmond";
			};
		};

		systemd.user.timers."batmond" = {
			Unit = {
				Description = "Periodic battery level check";
			};

			Timer = {
				OnBootSec = "1min";
				OnUnitActiveSec = "${toString cfg.batteryInterval}s";
				AccuracySec = "10s";
				Persistent = true;
			};

			Install = {
				WantedBy = [ "timers.target" ];
			};
		};
  };
}
