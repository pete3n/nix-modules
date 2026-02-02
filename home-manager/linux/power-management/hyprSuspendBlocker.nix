# Block systemctl suspend under specific conditions
{
  lib,
  pkgs,
  config,
  ...
}:

let
  cfg = config.programs.hyprSuspendBlocker;

  hyprSuspendBlocker =
    pkgs.writeShellScriptBin "hypr-suspend-blocker" # sh
      ''
				set -eu

				# Space-separated list of blockers
				BLOCKERS_JSON=${lib.escapeShellArg (builtins.toJSON cfg.blockers)}
				INT_CFG="${cfg.intDisplay}"

				state_power=""
				state_lid=""
				state_ext_disp=""
				int_disp=""
				do_print=0
				dry_run=0

				log() { 
					printf '%s\n' "$*" >&2; 
				}

				detect_internal() {
					_mons="$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null)" || return 1

					_int="$(printf '%s' "$_mons" | ${pkgs.jq}/bin/jq -r '
						[ .[] | .name ] | map(select(test("^(eDP|LVDS)-"))) | .[0] // empty
					' 2>/dev/null)" || true
					[ -n "$_int" ] && { printf '%s\n' "$_int"; return 0; }

					# Fallback: if exactly one enabled monitor exists, assume internal
					_int="$(printf '%s' "$_mons" | ${pkgs.jq}/bin/jq -r '
						[ .[] | select(.disabled == false) | .name ] as $n
						| if ($n|length)==1 then $n[0] else empty end
					' 2>/dev/null)" || true
					[ -n "$_int" ] && { printf '%s\n' "$_int"; return 0; }

					return 1
				}

				check_external_disp() {
					_mons="$(${pkgs.hyprland}/bin/hyprctl monitors -j 2>/dev/null)" || { printf 'unknown\n'; return 0; }

					if [ -z "$int_disp" ]; then
						# can't tell internal vs external reliably
						printf 'unknown\n'
						return 0
					fi

					if printf '%s' "$_mons" | ${pkgs.jq}/bin/jq -e --arg i "$int_disp" \
						'[ .[] | select(.disabled == false and .name != $i) ] | length > 0' \
						>/dev/null 2>&1
					then
						printf 'connected\n'
					else
						printf 'none\n'
					fi
				}

				get_internal() {
					if [ "$INT_CFG" != "auto" ]; then
						printf '%s\n' "$INT_CFG"
						return 0
					fi

					if _det="$(detect_internal 2>/dev/null)"; then
						[ -n "$_det" ] && { printf '%s\n' "$_det"; return 0; }
					fi

					log "internal display auto-detect failed; set programs.hyprSuspendBlocker.intDisplay"
					return 1
				}

				check_power() {
					# AC if any "online" is 1
					for _file in /sys/class/power_supply/*/online; do
						[ -r "$_file" ] || continue
						_online="$(cat "$_file" 2>/dev/null || true)"
						[ "$_online" = "1" ] && { printf "extPower\n"; return 0; }
					done

					# Battery if a Battery device exists and no AC online
					for _type in /sys/class/power_supply/*/type; do
						[ -r "$_type" ] || continue
						[ "$(cat "$_type" 2>/dev/null || true)" = "Battery" ] && { printf "onBattery\n"; return 0; }
					done

					printf "unknown\n"
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

				# Condition evaluators (return 0=true, 1=false)
				block_suspend() {
					case "$1" in
						lidOpen)     [ "$state_lid" = "open" ] ;;
						lidClosed)   [ "$state_lid" = "closed" ] ;;
						extPower)     [ "$state_power" = "extPower" ] ;;
						onBattery)   [ "$state_power" = "onBattery" ] ;;
						extDisplay)  [ "$state_ext_disp" = "connected" ] ;;
						*)
							printf "Unknown condition: $1\n" >&2
							return 1
							;;
					esac
				}

				print_state() {
					printf 'power=%s\n' "$state_power"
					printf 'lid=%s\n' "$state_lid"
					printf 'extDisplay=%s\n' "$state_ext_disp"
					printf 'blockers=%s\n' "$BLOCKERS_JSON"
				}

				while [ $# -gt 0 ]; do
					case "$1" in
						--print) do_print=1 ;;
						--dry-run) dry_run=1 ;;
						"") : ;;
						*) printf 'invalid argument: %s\n' "$1" >&2; exit 2 ;;
					esac
					shift
				done

				state_power="$(check_power)"   # extPower|onBattery|unknown
				state_lid="$(check_lid)"       # open|closed|unknown
				int_disp="$(get_internal 2>/dev/null || printf "")"
				state_ext_disp="$(check_external_disp)"

				if [ "$do_print" -eq 1 ]; then
					print_state
					exit 0
				fi

				# Return 0 if the given group (JSON array of strings) is met (AND).
				blocker_cond_met() {
					_group_json="$1"

					# Empty group: treat as false (don’t accidentally block everything)
					_len="$(printf '%s' "$_group_json" | ${pkgs.jq}/bin/jq 'length' 2>/dev/null || printf 0)"
					[ "$_len" -gt 0 ] || return 1

					printf '%s' "$_group_json" | ${pkgs.jq}/bin/jq -r '.[]' | while IFS= read -r _cond; do
						if ! block_suspend "$_cond"; then
							exit 1
						fi
					done
				}

				# True if ANY group is satisfied (OR).
				blocker_list_met() {
					# Empty outer list => no blockers (allow suspend)
					_outer_len="$(printf '%s' "$BLOCKERS_JSON" | ${pkgs.jq}/bin/jq 'length' 2>/dev/null || printf 0)"
					[ "$_outer_len" -gt 0 ] || return 1

					printf '%s' "$BLOCKERS_JSON" | ${pkgs.jq}/bin/jq -c '.[]' | while IFS= read -r _group; do
						if blocker_cond_met "$_group"; then
							exit 0
						fi
					done

					exit 1
				}

				if blocker_list_met; then
					printf "A blocker group matched -> not suspending\n"
					print_state
					exit 0
				fi

				printf "No blocker groups matched -> suspending\n"
				print_state
				[ "$dry_run" -eq 1 ] && exit 0
				exec ${pkgs.systemd}/bin/systemctl suspend

				echo "All conditions satisfied -> not suspending"
				print_state
				exit 0
      '';
in
{
	config = lib.mkIf cfg.enable {
		home.packages = [ hyprSuspendBlocker ];
		assertions = [
			{
				assertion = !(lib.elem "lidOpen" cfg.blockers && lib.elem "lidClosed" cfg.blockers);
				message = "hyprSuspendBlocker: cannot set both lidOpen and lidClosed blockers.";
			}
			{
				assertion = !(lib.elem "extPower" cfg.blockers && lib.elem "onBattery" cfg.blockers);
				message = "hyprSuspendBlocker: cannot set both extPower and onBattery blockers.";
			}
		];
	};

  options.programs.hyprSuspendBlocker = {
    enable = lib.mkEnableOption "Configure systemctl suspend blockers.";

    intDisplay = lib.mkOption {
      type = lib.types.str;
      default = "auto";
			example = "eDP-1";
			description = ''
				Internal panel output name used to detect external monitors. 
				(Hyprland monitor name). Default: auto;
			'';
    };

		blockers = lib.mkOption {
			type = lib.types.listOf (lib.types.listOf (lib.types.enum [
				"lidOpen"
				"lidClosed"
				"extDisplay"
				"extPower"
				"onBattery"
			]));
			default = [ [ "extPower" ] ];
			example = [
				[ "extPower" ]
				[ "extDisplay" "lidClosed" ]
			];
			description = ''
				List of blocker lists. Each inner list is AND'ed; the outer list is OR'ed.
				Suspend is blocked if any group evaluates to true.

				Example:
					blockers = [
						[ "extPower" ]
						[ "extDisplay" "lidClosed" ]
					];
			'';
		};
  };
}
