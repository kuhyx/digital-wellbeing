#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Function to show usage
show_usage() {
	echo "Day-Specific Auto-Shutdown Setup for Arch Linux"
	echo "==============================================="
	echo "Usage: $0 [enable|status]"
	echo ""
	echo "Commands:"
	echo "  enable   - Set up automatic shutdown with day-specific windows (default)"
	echo "  status   - Show current status"
	echo ""
	echo "Shutdown Schedule:"
	echo "  Monday-Wednesday: ${SCHEDULE_MON_WED_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo "  Thursday-Sunday:  ${SCHEDULE_THU_SUN_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo ""
	echo "NOTE: There is no 'disable' option. This is intentional."
	echo "      The shutdown timer is protected by a monitor service."
	echo ""
}

# Function to check and request sudo privileges
check_sudo() {
	if [[ $EUID -ne 0 ]]; then
		echo "This script requires sudo privileges to manage systemd services."
		echo "Requesting sudo access..."
		exec sudo "$0" "$@"
	fi
}

# Function to show current status
show_current_status() {
	echo "Day-Specific Auto-Shutdown Status"
	echo "================================="
	echo "Current Date: $(date)"
	echo "User: $ACTUAL_USER"
	echo ""

	local timer_exists=false

	# Check if files exist
	if [[ -f "/etc/systemd/system/day-specific-shutdown.timer" ]]; then
		timer_exists=true
		echo "✓ Timer file exists"
	else
		echo "✗ Timer file missing"
	fi

	if [[ -f "/etc/systemd/system/day-specific-shutdown.service" ]]; then
		echo "✓ Service file exists"
	else
		echo "✗ Service file missing"
	fi

	if [[ -f "/usr/local/bin/day-specific-shutdown-manager.sh" ]]; then
		echo "✓ Management script exists"
	else
		echo "✗ Management script missing"
	fi

	if [[ -f "/usr/local/bin/shutdown-timer-monitor.sh" ]]; then
		echo "✓ Monitor script exists"
	else
		echo "✗ Monitor script missing"
	fi

	echo ""

	# Check systemd status
	if $timer_exists; then
		if systemctl is-enabled day-specific-shutdown.timer &>/dev/null; then
			echo "✓ Timer is enabled"
			if systemctl is-active day-specific-shutdown.timer &>/dev/null; then
				echo "✓ Timer is active"
				echo ""
				echo "Next scheduled shutdown check:"
				systemctl list-timers day-specific-shutdown.timer --no-pager 2>/dev/null | grep day-specific-shutdown || echo "Timer information not available"
			else
				echo "✗ Timer is not active"
			fi
		else
			echo "✗ Timer is not enabled"
		fi
	else
		echo "Status: NOT CONFIGURED"
	fi

	echo ""

	# Check monitor service status
	echo "Monitor Service Status:"
	if systemctl is-enabled shutdown-timer-monitor.service &>/dev/null; then
		echo "✓ Monitor is enabled"
		if systemctl is-active shutdown-timer-monitor.service &>/dev/null; then
			echo "✓ Monitor is active (will re-enable timer if disabled)"
		else
			echo "✗ Monitor is not active"
		fi
	else
		echo "✗ Monitor is not enabled"
	fi

	echo ""

	# Check config file protection status (via guard-lib)
	echo "Config File Protection Status:"
	local canonical_file
	canonical_file="$(canonical_config_path)"

	if [[ -f $CONFIG_FILE ]]; then
		echo "✓ Config file exists"
		# Check immutable attribute
		if lsattr "$CONFIG_FILE" 2>/dev/null | grep -q '^....i'; then
			echo "✓ Config file is immutable (chattr +i)"
		else
			echo "✗ Config file is NOT immutable"
		fi
	else
		echo "✗ Config file missing"
	fi

	if [[ -n $canonical_file ]] && [[ -f $canonical_file ]]; then
		echo "✓ Canonical copy exists ($canonical_file)"
	else
		echo "✗ Canonical copy missing (guard-lib instance not installed?)"
	fi

	if systemctl is-enabled "guard-file@${GUARD_NAME}.path" &>/dev/null; then
		echo "✓ Config path watcher is enabled"
		if systemctl is-active "guard-file@${GUARD_NAME}.path" &>/dev/null; then
			echo "✓ Config path watcher is active"
		else
			echo "✗ Config path watcher is not active"
		fi
	else
		echo "✗ Config path watcher is not enabled"
	fi

	echo ""
	echo "Shutdown Schedule:"
	echo "  Monday-Wednesday: ${SCHEDULE_MON_WED_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo "  Thursday-Sunday:  ${SCHEDULE_THU_SUN_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00"
	echo ""
	echo "NOTE: The shutdown timer is protected by a monitor service."
	echo "      If you try to disable the timer, it will be automatically re-enabled."
	echo ""
	echo "NOTE: The config file is protected by:"
	echo "      - Immutable attribute (chattr +i)"
	echo "      - Canonical copy that auto-restores on modification"
	echo "      - Path watcher service"
	echo ""

	echo "Active Overrides:"
	if command -v /usr/local/bin/shutdown-override-manager.sh >/dev/null 2>&1; then
		/usr/local/bin/shutdown-override-manager.sh list | sed 's/^/  /'
	else
		echo "  (override manager not installed)"
	fi
	echo ""
}

# Display the shutdown schedule (used in multiple places)
print_shutdown_schedule() {
	# Convert 24h to 12h format for display
	local mon_wed_12h thu_sun_12h morning_12h
	if [[ $SCHEDULE_MON_WED_HOUR -gt 12 ]]; then
		mon_wed_12h="$((SCHEDULE_MON_WED_HOUR - 12)):00 PM"
	else
		mon_wed_12h="${SCHEDULE_MON_WED_HOUR}:00 AM"
	fi
	if [[ $SCHEDULE_THU_SUN_HOUR -gt 12 ]]; then
		thu_sun_12h="$((SCHEDULE_THU_SUN_HOUR - 12)):00 PM"
	else
		thu_sun_12h="${SCHEDULE_THU_SUN_HOUR}:00 AM"
	fi
	morning_12h="${SCHEDULE_MORNING_END_HOUR}:00 AM"

	echo "Shutdown Schedule:"
	echo "  Monday-Wednesday: ${SCHEDULE_MON_WED_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00 (${mon_wed_12h} to ${morning_12h})"
	echo "  Thursday-Sunday:  ${SCHEDULE_THU_SUN_HOUR}:00-0${SCHEDULE_MORNING_END_HOUR}:00 (${thu_sun_12h} to ${morning_12h})"
}
