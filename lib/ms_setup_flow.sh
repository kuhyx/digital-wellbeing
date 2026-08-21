#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Function to test the setup
test_setup() {
	echo ""
	echo "8. Testing Setup..."
	echo "=================="

	echo "Service files:"
	if [[ -f "/etc/systemd/system/day-specific-shutdown.service" ]]; then
		echo "✓ Service file exists"
	else
		echo "✗ Service file missing"
	fi

	if [[ -f "/etc/systemd/system/day-specific-shutdown.timer" ]]; then
		echo "✓ Timer file exists"
	else
		echo "✗ Timer file missing"
	fi

	if [[ -f "/etc/systemd/system/shutdown-timer-monitor.service" ]]; then
		echo "✓ Monitor service file exists"
	else
		echo "✗ Monitor service file missing"
	fi

	echo ""
	echo "Timer status:"
	if systemctl is-enabled day-specific-shutdown.timer &>/dev/null; then
		echo "✓ Timer is enabled"
	else
		echo "✗ Timer is not enabled"
	fi

	if systemctl is-active day-specific-shutdown.timer &>/dev/null; then
		echo "✓ Timer is active"
	else
		echo "✗ Timer is not active"
	fi

	echo ""
	echo "Monitor status:"
	if systemctl is-enabled shutdown-timer-monitor.service &>/dev/null; then
		echo "✓ Monitor is enabled"
	else
		echo "✗ Monitor is not enabled"
	fi

	if systemctl is-active shutdown-timer-monitor.service &>/dev/null; then
		echo "✓ Monitor is active"
	else
		echo "✗ Monitor is not active"
	fi

	echo ""
	echo "Watchdog timer status:"
	if systemctl is-enabled shutdown-timer-monitor-watchdog.timer &>/dev/null; then
		echo "✓ Watchdog timer is enabled"
	else
		echo "✗ Watchdog timer is not enabled"
	fi

	if systemctl is-active shutdown-timer-monitor-watchdog.timer &>/dev/null; then
		echo "✓ Watchdog timer is active"
	else
		echo "✗ Watchdog timer is not active"
	fi

	echo ""
	echo "Config file protection status:"
	local canonical_file
	canonical_file="$(canonical_config_path)"

	if [[ -f $CONFIG_FILE ]]; then
		echo "✓ Config file exists"
		if lsattr "$CONFIG_FILE" 2>/dev/null | grep -q '^....i'; then
			echo "✓ Config file is immutable"
		else
			echo "✗ Config file is NOT immutable"
		fi
	else
		echo "✗ Config file missing"
	fi

	if [[ -n $canonical_file ]] && [[ -f $canonical_file ]]; then
		echo "✓ Canonical copy exists"
	else
		echo "✗ Canonical copy missing"
	fi

	if systemctl is-enabled "guard-file@${GUARD_NAME}.path" &>/dev/null; then
		echo "✓ Config guard path watcher is enabled"
	else
		echo "✗ Config guard path watcher is not enabled"
	fi

	if systemctl is-active "guard-file@${GUARD_NAME}.path" &>/dev/null; then
		echo "✓ Config guard path watcher is active"
	else
		echo "✗ Config guard path watcher is not active"
	fi

	echo ""
	echo "Next scheduled checks:"
	if ! systemctl list-timers day-specific-shutdown.timer --no-pager 2>/dev/null | head -5 | grep day-specific-shutdown; then
		echo "Timer information not available"
	fi
}

# Function to show final instructions
show_instructions() {
	echo ""
	echo "================================================="
	echo "Day-Specific Auto-Shutdown Setup Complete"
	echo "================================================="
	echo "Summary:"
	echo "✓ Systemd service created (/etc/systemd/system/day-specific-shutdown.service)"
	echo "✓ Systemd timer created (/etc/systemd/system/day-specific-shutdown.timer)"
	echo "✓ Management script created (/usr/local/bin/day-specific-shutdown-manager.sh)"
	echo "✓ Smart check script created (/usr/local/bin/day-specific-shutdown-check.sh)"
	echo "✓ Timer enabled and started"
	echo "✓ Monitor service installed (protects timer from being disabled)"
	echo "✓ Watchdog timer installed (restarts monitor if stopped)"
	echo "✓ Config file protected (immutable + path watcher + canonical copy)"
	echo ""
	print_shutdown_schedule
	echo ""
	echo "Management commands:"
	echo "  sudo day-specific-shutdown-manager.sh status   - Check status"
	echo "  sudo day-specific-shutdown-manager.sh logs     - View shutdown logs"
	echo ""
	echo "How it works:"
	echo "• Timer checks every 30 minutes during potential shutdown windows"
	echo "• Smart logic determines shutdown eligibility based on day and time"
	echo "• Monitor service watches the timer and re-enables it if disabled"
	echo "• Watchdog timer restarts the monitor every 60 seconds if stopped"
	echo "• Monitor has RefuseManualStop=true to prevent easy stopping"
	echo "• Config file is protected by multiple security layers"
	echo "• There is NO disable option - this is intentional for digital wellbeing"
	echo ""
	echo "WARNING: This will automatically shutdown your PC during designated hours."
	echo "Make sure to save your work before the shutdown windows!"
	echo ""
}

# Function to prompt for confirmation
confirm_setup() {
	echo ""
	echo "WARNING: Day-Specific Auto-Shutdown Confirmation"
	echo "==============================================="
	echo "This will set up your PC to automatically shutdown during specific time windows."
	echo ""
	print_shutdown_schedule
	echo ""
	echo "Important considerations:"
	echo "- Any unsaved work will be lost during shutdown windows"
	echo "- Running processes will be terminated"
	echo "- Downloads/uploads in progress will be interrupted"
	echo "- You'll need to manually power on your PC each day"
	echo "- Timer checks every 30 minutes during potential shutdown windows"
	echo "- There is NO disable option - this is protected by a monitor service"
	echo ""
	read -r -p "Do you want to proceed? (y/N): " confirm

	case "$confirm" in
	[yY] | [yY][eE][sS])
		echo "Proceeding with setup..."
		return 0
		;;
	*)
		echo "Setup cancelled."
		exit 0
		;;
	esac
}

# Main execution flow for enable
enable_midnight_shutdown() {
	echo "Day-Specific Auto-Shutdown Setup for Arch Linux"
	echo "==============================================="
	echo "Current Date: $(date)"
	echo "User: $ACTUAL_USER"
	echo "Target user: $ACTUAL_USER"
	echo "User home: $USER_HOME"

	# Check if trying to cheat by making schedule more lenient
	check_schedule_protection

	# Confirm setup
	confirm_setup

	# Create config file (shared with i3blocks countdown script)
	create_shutdown_config

	# Create config guard (path watcher, enforcement, unlock script)
	create_config_guard

	# Create systemd files
	create_shutdown_service
	create_shutdown_timer
	create_management_script
	create_shutdown_check_script
	create_override_manager_script

	# Enable and start timer
	enable_timer

	# Install monitor service (protects timer from being disabled)
	install_monitor_service

	# Test setup
	test_setup

	# NOTE: this used to `chattr +i` its own source ("lock this setup script so
	# values + checks can't be silently edited"). Do NOT reintroduce that: making
	# a git-tracked file immutable breaks git. pre-commit clears unstaged changes
	# with `git checkout -- .`; that unlink fails with "Operation not permitted"
	# on an immutable file, the context manager aborts, and the restore never
	# runs — silently reverting your OTHER unstaged edits on every commit/push.
	#
	# Enforcement does not depend on it: /etc/shutdown-schedule.conf is chattr +i,
	# guard-lib keeps a canonical snapshot + path watcher that re-enforces it, the
	# monitor service protects the timer, and screen_locker's ratchet only accepts
	# same-or-stricter values. Editing this source changes nothing until setup is
	# re-run as root, which rewrites the guarded config anyway.

	# Show instructions
	show_instructions
}
