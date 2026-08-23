#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Determine if this invocation may perform a transaction (upgrade/install/remove)
needs_unlock() {
	# If args include -S (install/upgrade), -U (local install), or -R (remove), we unlock
	# Also include -Su/-Syu/-Syuu when -S is part of the combined flag
	for arg in "$@"; do
		case "$arg" in
		-S*)
			return 0
			;;
		-U)
			return 0
			;;
		-R)
			return 0
			;;
		--sync)
			return 0
			;;
		--upgrade)
			return 0
			;;
		--remove)
			return 0
			;;
		esac
	done
	return 1
}

pacman_hooks_manage_guard_lib() {
	local pre_hook="/etc/pacman.d/hooks/10-guard-lib-unlock-all.hook"
	local post_hook="/etc/pacman.d/hooks/90-guard-lib-relock-all.hook"
	local pre_exec="/etc/guard-lib/pacman-hooks/guard-lib-unlock-all.sh"
	local post_exec="/etc/guard-lib/pacman-hooks/guard-lib-relock-all.sh"

	if [[ ! -f $pre_hook || ! -f $post_hook ]]; then
		return 1
	fi

	grep -Fq "$pre_exec" "$pre_hook" && grep -Fq "$post_exec" "$post_hook"
}

should_use_wrapper_guard_lib_fallback() {
	if ! needs_unlock "$@"; then
		return 1
	fi

	if pacman_hooks_manage_guard_lib; then
		return 1
	fi

	return 0
}

# Run guard-lib's own generic unlock-all/relock-all scripts directly if
# pacman's own hooks for them are missing (e.g. hooks disabled/misconfigured).
# These cover every registered file-guard instance (hosts, nsswitch,
# resolved, shutdown-schedule, ...), not just /etc/hosts.
pre_unlock_guard_lib() {
	local pre="/etc/guard-lib/pacman-hooks/guard-lib-unlock-all.sh"
	if [[ -x $pre ]]; then
		echo -e "${CYAN}[guard-lib] Preparing guarded files for transaction...${NC}" >&2
		/bin/bash "$pre" || true
	fi
}

post_relock_guard_lib() {
	local post="/etc/guard-lib/pacman-hooks/guard-lib-relock-all.sh"
	if [[ -x $post ]]; then
		/bin/bash "$post" || true
		echo -e "${CYAN}[guard-lib] Protections re-applied to guarded files.${NC}" >&2
	fi
}

# Ensure periodic system services (timer/monitor) are set up; if not, trigger setup
ensure_periodic_maintenance() {
	# Only proceed if systemd/systemctl is available
	if ! command -v systemctl >/dev/null 2>&1; then
		return 0
	fi

	local timer_unit="periodic-system-maintenance.timer"
	local startup_unit="periodic-system-startup.service"
	local monitor_unit="hosts-file-monitor.service"
	local needs_setup=0

	# Timer should be enabled and active
	systemctl --quiet is-enabled "$timer_unit" || needs_setup=1
	systemctl --quiet is-active "$timer_unit" || needs_setup=1

	# Monitor should be enabled and active
	systemctl --quiet is-enabled "$monitor_unit" || needs_setup=1
	systemctl --quiet is-active "$monitor_unit" || needs_setup=1

	# Startup service should be enabled (it’s oneshot and may not be active except at boot)
	systemctl --quiet is-enabled "$startup_unit" || needs_setup=1

	if [[ $needs_setup -eq 0 ]]; then
		return 0
	fi

	echo -e "${YELLOW}Periodic maintenance services missing or inactive. Running setup...${NC}" >&2

	# Try to locate setup_periodic_system.sh. The installed wrapper lives in
	# /usr/local/bin (so $self_dir won't contain it) and, for real transactions,
	# runs as root under sudo (so $HOME points at /root). Resolve the invoking
	# user's home via SUDO_USER and probe the known repo locations.
	local setup_script=""
	local self_dir real_user real_home
	self_dir="$(dirname "$(readlink -f "$0")")"
	real_user="${SUDO_USER:-${USER:-$(id -un)}}"
	real_home="$(getent passwd "$real_user" 2>/dev/null | cut -d: -f6)"
	[[ -z $real_home ]] && real_home="$HOME"

	local -a setup_candidates=(
		"$self_dir/setup_periodic_system.sh"
		"$real_home/testsAndMisc/linux_configuration/periodic_background/setup_periodic_system.sh"
		"$real_home/linux_configuration/periodic_background/setup_periodic_system.sh"
		"$real_home/linux-configuration/scripts/periodic_background/setup_periodic_system.sh"
	)
	local candidate
	for candidate in "${setup_candidates[@]}"; do
		if [[ -f $candidate ]]; then
			setup_script="$candidate"
			break
		fi
	done

	if [[ -n $setup_script ]]; then
		if [[ $EUID -ne 0 ]]; then
			sudo bash "$setup_script"
		else
			bash "$setup_script"
		fi
		echo -e "${CYAN}Tip:${NC} To disable these later:" >&2
		echo "  sudo systemctl disable periodic-system-maintenance.timer" >&2
		echo "  sudo systemctl disable periodic-system-startup.service" >&2
		echo "  sudo systemctl disable hosts-file-monitor.service" >&2
	else
		echo -e "${RED}Could not locate setup_periodic_system.sh to configure services automatically.${NC}" >&2
	fi
}
