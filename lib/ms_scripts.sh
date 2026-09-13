#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Function to create smart shutdown check script
create_shutdown_check_script() {
	echo ""
	echo "6. Creating Smart Shutdown Check Script..."
	echo "========================================"

	local check_script="/usr/local/bin/day-specific-shutdown-check.sh"

	cat >"$check_script" <<'EOF'
#!/bin/bash
# Smart day-specific shutdown check script
# Reads shutdown windows from /etc/shutdown-schedule.conf

CONFIG_FILE="/etc/shutdown-schedule.conf"
OVERRIDES_FILE="/etc/shutdown-schedule-overrides.conf"

# Time-boxed exceptions (e.g. watching a live event that runs past the normal
# shutdown window) are registered via shutdown-override-manager.sh, which
# appends "start_epoch|end_epoch|created_epoch|reason" lines to OVERRIDES_FILE.
# Entries are absolute-epoch-bound so they expire on their own; this function
# prunes stale lines and returns success (skip shutdown) if now falls inside
# any remaining window.
check_active_override() {
    [[ -f "$OVERRIDES_FILE" ]] || return 1

    local now
    now=$(printf '%(%s)T' -1)

    local kept=""
    local active=false
    local active_reason=""
    local start_epoch end_epoch _created reason

    while IFS='|' read -r start_epoch end_epoch _created reason; do
        [[ -n "$start_epoch" ]] || continue
        if [[ $end_epoch -lt $now ]]; then
            continue # expired, drop it
        fi
        kept+="${start_epoch}|${end_epoch}|${_created}|${reason}"$'\n'
        if [[ $now -ge $start_epoch ]] && [[ $now -le $end_epoch ]]; then
            active=true
            active_reason="$reason"
        fi
    done <"$OVERRIDES_FILE"

    printf '%s' "$kept" >"$OVERRIDES_FILE"

    if [[ $active == true ]]; then
        logger -t day-specific-shutdown "Active override in effect (reason: ${active_reason}) - skipping shutdown check"
        return 0
    fi
    return 1
}

if check_active_override; then
    exit 0
fi

# Load config
if [[ ! -f "$CONFIG_FILE" ]]; then
    logger -t day-specific-shutdown "ERROR: Config file $CONFIG_FILE not found"
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validate config
if [[ -z "${MON_WED_HOUR:-}" ]]; then
	logger -t day-specific-shutdown "ERROR: Config file missing required variables"
	exit 1
fi
if [[ -z "${THU_SUN_HOUR:-}" ]]; then
	logger -t day-specific-shutdown "ERROR: Config file missing required variables"
	exit 1
fi
if [[ -z "${MORNING_END_HOUR:-}" ]]; then
    logger -t day-specific-shutdown "ERROR: Config file missing required variables"
    exit 1
fi

# Get current time and day (fork-free bash builtins)
current_hour=$(printf '%(%H)T' -1)
current_minute=$(printf '%(%M)T' -1)
current_time_minutes=$((10#$current_hour * 60 + 10#$current_minute))
day_of_week=$(printf '%(%u)T' -1)  # 1=Monday, 7=Sunday
day_name=$(printf '%(%A)T' -1)

# Calculate minute thresholds from config
mon_wed_minutes=$((MON_WED_HOUR * 60))
thu_sun_minutes=$((THU_SUN_HOUR * 60))
morning_end_minutes=$((MORNING_END_HOUR * 60))

# Determine if we should shutdown based on day and time. Silent outside the
# window: the timer fires every minute all day, so an out-of-window run must
# leave nothing in the journal (four lines a minute was 6k lines a day).
should_shutdown=false
if [[ $day_of_week -ge 1 ]] && [[ $day_of_week -le 3 ]]; then
    # Monday (1), Tuesday (2), Wednesday (3)
    shutdown_start=$mon_wed_minutes
    window_label="${MON_WED_HOUR}:00-0${MORNING_END_HOUR}:00"
else
    # Thursday (4), Friday (5), Saturday (6), Sunday (7)
    shutdown_start=$thu_sun_minutes
    window_label="${THU_SUN_HOUR}:00-0${MORNING_END_HOUR}:00"
fi

if [[ $current_time_minutes -ge $shutdown_start ]] || [[ $current_time_minutes -lt $morning_end_minutes ]]; then
    should_shutdown=true
    logger -t day-specific-shutdown "$day_name $current_hour:$current_minute is inside the $window_label shutdown window"
fi

if [[ $should_shutdown == true ]]; then
    printf '%(%Y-%m-%d %H:%M:%S)T: Executing shutdown - current time %s:%s is within shutdown window for %s\n' -1 "$current_hour" "$current_minute" "$day_name"
    logger -t day-specific-shutdown "Executing scheduled shutdown at $(printf '%(%Y-%m-%d %H:%M:%S)T' -1)"

    # Night lockdown instead of power-off. This machine is a 24/7 home server
    # (Gitea, the Caddy TLS edge, SyncYomi, the personal website, Open WebUI,
    # Joplin, dufs, ollama, dnsmasq, wg-quick@wg0, nftables, sshd). Powering off
    # took every server down with it. The lockdown action tears down the user GUI
    # and masks the TTY login surface so the machine is unusable from the keyboard,
    # while all servers keep running. See setup_night_lockdown.sh. The morning
    # unlock (night-lockdown-unlock.timer) restores the desktop at 05:00, so the
    # old rtcwake/hibernate wake-for-alarm path is no longer needed — the machine
    # simply stays on all night. DRY_RUN passes through so
    # `DRY_RUN=1 day-specific-shutdown-check.sh` exercises the path without locking.
    logger -t day-specific-shutdown "Entering night lockdown (servers stay up) via /usr/local/bin/night-lockdown-enter.sh"
    DRY_RUN="${DRY_RUN:-}" /usr/local/bin/night-lockdown-enter.sh
elif [[ -n "${DRY_RUN:-}" ]]; then
    # Only a dry run reports the quiet path; the per-minute timer must not.
    printf '%(%Y-%m-%d %H:%M:%S)T: Skipping shutdown - not within shutdown window for %s (current: %s:%s)\n' -1 "$day_name" "$current_hour" "$current_minute"
fi
EOF

	chmod +x "$check_script"
	echo "✓ Created smart shutdown check script: $check_script"
}
