#!/bin/bash
# Script to set up automatic PC shutdown with day-specific time windows
# Monday-Wednesday: Shutdown between 21:00-05:00
# Thursday-Sunday: Shutdown between 22:00-05:00
# Handles sudo privileges automatically

set -e # Exit on any error

# Source common library for shared functions
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
# shellcheck source=../../lib/common.sh
source "$SCRIPT_DIR/../../lib/common.sh"

# The phases live in lib/ms_*.sh. SCRIPT_DIR is resolved with readlink -f
# above, so this resolves through a symlinked entry point too.
# shellcheck source=lib/ms_guard.sh
source "$SCRIPT_DIR/lib/ms_guard.sh"
# shellcheck source=lib/ms_config_guard.sh
source "$SCRIPT_DIR/lib/ms_config_guard.sh"
# shellcheck source=lib/ms_scripts.sh
source "$SCRIPT_DIR/lib/ms_scripts.sh"
# shellcheck source=lib/ms_override_mgr.sh
source "$SCRIPT_DIR/lib/ms_override_mgr.sh"
# shellcheck source=lib/ms_monitor.sh
source "$SCRIPT_DIR/lib/ms_monitor.sh"
# shellcheck source=lib/ms_units.sh
source "$SCRIPT_DIR/lib/ms_units.sh"
# shellcheck source=lib/ms_report.sh
source "$SCRIPT_DIR/lib/ms_report.sh"
# shellcheck source=lib/ms_setup_flow.sh
source "$SCRIPT_DIR/lib/ms_setup_flow.sh"

# Schedule constants (single source of truth for this script)
# These values are written to /etc/shutdown-schedule.conf during setup
SCHEDULE_MON_WED_HOUR=21
# Thu-Sun aligned to 21:00 to match the canonical schedule that screen_locker's
# sick-day feature ratcheted in (was 22); the ratchet only permits same/stricter.
SCHEDULE_THU_SUN_HOUR=21
SCHEDULE_MORNING_END_HOUR=5

# ============================================================================
# SCHEDULE PROTECTION MECHANISM
# ============================================================================
# This prevents easy "cheating" by modifying the script values and re-running.
# If a canonical config already exists, the script compares against it and
# BLOCKS installation if the new values would make the schedule MORE LENIENT
# (i.e., later shutdown hours or earlier morning end).
#
# The mechanical protection (chattr, canonical snapshot, path watcher,
# pacman-hook) is provided by guard-lib (guardctl); this ratchet logic and
# the conditional-delay unlock flow below are specific to this one guard
# target and stay bespoke - guardctl's generic `unlock` can't represent
# "hard-block one field, delay only if lenient, no delay if stricter".
# ============================================================================

GUARD_NAME="shutdown-schedule"
CONFIG_FILE="/etc/shutdown-schedule.conf"


# Validate that the schedule allows at least MIN_USAGE_HOURS of continuous PC usage.
# The usable window is from SCHEDULE_MORNING_END_HOUR until each shutdown hour.
# Both shutdown hours must independently satisfy the minimum (10 hours).
MIN_USAGE_HOURS=10


# Validate schedule constants immediately (before any sudo escalation or file writes)
validate_minimum_usage_window




# Get the actual user (even when running with sudo)
set_actual_user_vars
















# Parse command line arguments
case "${1:-enable}" in
"enable")
	check_sudo "$@"
	enable_midnight_shutdown
	;;
"status")
	check_sudo "$@"
	show_current_status
	;;
"help" | "-h" | "--help")
	show_usage
	;;
*)
	echo "Error: Unknown command '$1'"
	echo ""
	show_usage
	exit 1
	;;
esac
