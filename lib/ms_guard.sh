#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Prints guard-lib's canonical path for our instance, or nothing if the
# instance isn't installed yet (first run on this machine).
canonical_config_path() {
	if command -v guardctl >/dev/null 2>&1 && guardctl file-guard status "$GUARD_NAME" >/dev/null 2>&1; then
		guardctl file-guard canonical-path "$GUARD_NAME"
	fi
}

validate_minimum_usage_window() {
	local mon_wed_window thu_sun_window
	mon_wed_window=$((SCHEDULE_MON_WED_HOUR - SCHEDULE_MORNING_END_HOUR))
	thu_sun_window=$((SCHEDULE_THU_SUN_HOUR - SCHEDULE_MORNING_END_HOUR))

	local errors=()

	if [[ $mon_wed_window -le 0 ]]; then
		errors+=("Mon-Wed: morning end (${SCHEDULE_MORNING_END_HOUR}:00) is at or after shutdown (${SCHEDULE_MON_WED_HOUR}:00) — 0 usable hours")
	elif [[ $mon_wed_window -lt $MIN_USAGE_HOURS ]]; then
		errors+=("Mon-Wed: only ${mon_wed_window}h of usable time (${SCHEDULE_MORNING_END_HOUR}:00–${SCHEDULE_MON_WED_HOUR}:00), need at least ${MIN_USAGE_HOURS}h")
	fi

	if [[ $thu_sun_window -le 0 ]]; then
		errors+=("Thu-Sun: morning end (${SCHEDULE_MORNING_END_HOUR}:00) is at or after shutdown (${SCHEDULE_THU_SUN_HOUR}:00) — 0 usable hours")
	elif [[ $thu_sun_window -lt $MIN_USAGE_HOURS ]]; then
		errors+=("Thu-Sun: only ${thu_sun_window}h of usable time (${SCHEDULE_MORNING_END_HOUR}:00–${SCHEDULE_THU_SUN_HOUR}:00), need at least ${MIN_USAGE_HOURS}h")
	fi

	if [[ ${#errors[@]} -gt 0 ]]; then
		echo ""
		echo "╔══════════════════════════════════════════════════════════════════╗"
		echo "║          ❌ INVALID SCHEDULE CONFIGURATION ❌                    ║"
		echo "╚══════════════════════════════════════════════════════════════════╝"
		echo ""
		echo "The schedule constants do not guarantee at least ${MIN_USAGE_HOURS} hours of"
		echo "continuous PC availability. This would cause the PC to shut down"
		echo "immediately or very shortly after it becomes usable."
		echo ""
		for err in "${errors[@]}"; do
			echo "  ✗ $err"
		done
		echo ""
		echo "Fix: ensure (SHUTDOWN_HOUR - MORNING_END_HOUR) >= ${MIN_USAGE_HOURS} for both windows."
		echo "     Example: MORNING_END_HOUR=6, SHUTDOWN_HOUR=22 → 16 usable hours ✓"
		echo ""
		exit 1
	fi
}

# Check if trying to make schedule more lenient (later shutdown / earlier morning end)
check_schedule_protection() {
	local canonical_config
	canonical_config="$(canonical_config_path)"

	# Skip check if no canonical config exists yet (first install)
	if [[ -z $canonical_config ]] || [[ ! -f $canonical_config ]]; then
		return 0
	fi

	# Load canonical values
	local canonical_mon_wed canonical_thu_sun canonical_morning_end
	# shellcheck source=/dev/null
	source "$canonical_config" 2>/dev/null || return 0
	canonical_mon_wed="${MON_WED_HOUR:-}"
	canonical_thu_sun="${THU_SUN_HOUR:-}"
	canonical_morning_end="${MORNING_END_HOUR:-}"

	# If canonical values are empty, skip check
	if [[ -z $canonical_mon_wed ]]; then
		return 0
	fi
	if [[ -z $canonical_thu_sun ]]; then
		return 0
	fi
	if [[ -z $canonical_morning_end ]]; then
		return 0
	fi

	local violations=()

	# Check if Mon-Wed hour is being made LATER (more lenient)
	if [[ $SCHEDULE_MON_WED_HOUR -gt $canonical_mon_wed ]]; then
		violations+=("Mon-Wed shutdown: ${canonical_mon_wed}:00 → ${SCHEDULE_MON_WED_HOUR}:00 (later)")
	fi

	# Check if Thu-Sun hour is being made LATER (more lenient)
	if [[ $SCHEDULE_THU_SUN_HOUR -gt $canonical_thu_sun ]]; then
		violations+=("Thu-Sun shutdown: ${canonical_thu_sun}:00 → ${SCHEDULE_THU_SUN_HOUR}:00 (later)")
	fi

	# Check if morning end is being made EARLIER (more lenient - shorter shutdown window)
	if [[ $SCHEDULE_MORNING_END_HOUR -lt $canonical_morning_end ]]; then
		violations+=("Morning end: 0${canonical_morning_end}:00 → 0${SCHEDULE_MORNING_END_HOUR}:00 (earlier)")
	fi

	if [[ ${#violations[@]} -gt 0 ]]; then
		echo ""
		echo "╔══════════════════════════════════════════════════════════════════╗"
		echo "║               ❌ OPERATION NOT PERMITTED ❌                      ║"
		echo "╚══════════════════════════════════════════════════════════════════╝"
		echo ""
		echo "The requested schedule modification has been denied."
		echo ""
		exit 1
	fi

	# Making schedule STRICTER is always allowed
	local stricter=()
	if [[ $SCHEDULE_MON_WED_HOUR -lt $canonical_mon_wed ]]; then
		stricter+=("Mon-Wed: ${canonical_mon_wed}:00 → ${SCHEDULE_MON_WED_HOUR}:00 (earlier)")
	fi
	if [[ $SCHEDULE_THU_SUN_HOUR -lt $canonical_thu_sun ]]; then
		stricter+=("Thu-Sun: ${canonical_thu_sun}:00 → ${SCHEDULE_THU_SUN_HOUR}:00 (earlier)")
	fi
	if [[ $SCHEDULE_MORNING_END_HOUR -gt $canonical_morning_end ]]; then
		stricter+=("Morning end: 0${canonical_morning_end}:00 → 0${SCHEDULE_MORNING_END_HOUR}:00 (later)")
	fi

	if [[ ${#stricter[@]} -gt 0 ]]; then
		echo ""
		echo "ℹ️  Schedule is being made STRICTER (allowed without unlock):"
		for s in "${stricter[@]}"; do
			echo "  • $s"
		done
		echo ""
	fi

	return 0
}
