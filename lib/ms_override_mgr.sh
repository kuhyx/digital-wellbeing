#!/usr/bin/env bash
# Helpers sourced by the entry script.

# Function to create the time-boxed override manager (event exceptions like
# watching a live match that runs past the normal shutdown window). Overrides
# are absolute-epoch-bound so they expire on their own; the friction (typed
# confirmation + delay) lives entirely in this CLI, matching the existing
# unlock script's philosophy for the permanent schedule ratchet.
create_override_manager_script() {
	echo ""
	echo "9. Creating Shutdown Override Manager..."
	echo "========================================"

	local overrides_file="/etc/shutdown-schedule-overrides.conf"
	local log_file="/var/log/shutdown-schedule-overrides.log"
	local manager_script="/usr/local/bin/shutdown-override-manager.sh"

	touch "$overrides_file"
	# World-readable (like shutdown-schedule.conf): the i3blocks countdown
	# script runs as the regular user and needs to read active overrides to
	# display them. Only root can write to it (via this manager script).
	chmod 644 "$overrides_file"
	touch "$log_file"
	chmod 600 "$log_file"

	cat >"$manager_script" <<'EOF'
#!/bin/bash
# Shutdown Override Manager
# Registers time-boxed exceptions to the day-specific-shutdown schedule, e.g.
# to watch a live event that runs past the normal shutdown window. Entries are
# absolute-epoch-bound and expire on their own - there is nothing to re-lock.

set -euo pipefail

OVERRIDES_FILE="/etc/shutdown-schedule-overrides.conf"
LOG_FILE="/var/log/shutdown-schedule-overrides.log"
MAX_OVERRIDE_HOURS=12
MAX_ACTIVE_OVERRIDES=3
MIN_REASON_LEN=10
CONFIRM_PHRASE="I am deliberately bypassing my shutdown protection"
DELAY_SECONDS=30

log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This command requires sudo." >&2
        exit 1
    fi
}

now_epoch() {
    printf '%(%s)T' -1
}

prune_and_read() {
    # Prints kept (non-expired) lines; overwrites OVERRIDES_FILE with them.
    local now kept=""
    now=$(now_epoch)
    if [[ -f "$OVERRIDES_FILE" ]]; then
        local start_epoch end_epoch created reason
        while IFS='|' read -r start_epoch end_epoch created reason; do
            [[ -n "$start_epoch" ]] || continue
            [[ "$end_epoch" -lt "$now" ]] && continue
            kept+="${start_epoch}|${end_epoch}|${created}|${reason}"$'\n'
        done <"$OVERRIDES_FILE"
    fi
    printf '%s' "$kept" >"$OVERRIDES_FILE"
    printf '%s' "$kept"
}

cmd_list() {
    local kept
    kept="$(prune_and_read)"
    if [[ -z "$kept" ]]; then
        echo "No active or upcoming overrides."
        return 0
    fi
    echo "Active/upcoming overrides:"
    local i=1
    local start_epoch end_epoch created reason
    while IFS='|' read -r start_epoch end_epoch created reason; do
        [[ -n "$start_epoch" ]] || continue
        printf '  [%d] %s -> %s  (reason: %s)\n' \
            "$i" \
            "$(date -d "@$start_epoch" '+%Y-%m-%d %H:%M')" \
            "$(date -d "@$end_epoch" '+%Y-%m-%d %H:%M')" \
            "$reason"
        i=$((i + 1))
    done <<<"$kept"
}

cmd_remove() {
    require_root
    local target="${1:-}"
    [[ -n "$target" ]] || { echo "Usage: $0 remove <line-number-from-list>" >&2; exit 1; }

    local kept
    kept="$(prune_and_read)"
    if [[ -z "$kept" ]]; then
        echo "No overrides to remove." >&2
        exit 1
    fi

    local new_content="" i=1 start_epoch end_epoch created reason removed=false
    while IFS='|' read -r start_epoch end_epoch created reason; do
        [[ -n "$start_epoch" ]] || continue
        if [[ "$i" == "$target" ]]; then
            removed=true
        else
            new_content+="${start_epoch}|${end_epoch}|${created}|${reason}"$'\n'
        fi
        i=$((i + 1))
    done <<<"$kept"

    if [[ "$removed" != true ]]; then
        echo "No override at index $target" >&2
        exit 1
    fi

    printf '%s' "$new_content" >"$OVERRIDES_FILE"
    log "Removed override index $target (by $(logname 2>/dev/null || echo unknown))"
    echo "✓ Removed override $target"
}

cmd_add() {
    require_root
    local start_str="${1:-}" end_str="${2:-}"
    local reason="${*:3}"

    if [[ -z "$start_str" ]] || [[ -z "$end_str" ]] || [[ -z "$reason" ]]; then
        echo "Usage: $0 add '<start datetime>' '<end datetime>' <reason>" >&2
        echo "Example: $0 add '2026-07-10 21:30' '2026-07-11 00:30' 'World Cup match'" >&2
        exit 1
    fi

    if [[ "${#reason}" -lt "$MIN_REASON_LEN" ]]; then
        echo "Reason must be at least $MIN_REASON_LEN characters." >&2
        exit 1
    fi

    local start_epoch end_epoch
    start_epoch=$(date -d "$start_str" +%s) || { echo "Could not parse start datetime: $start_str" >&2; exit 1; }
    end_epoch=$(date -d "$end_str" +%s) || { echo "Could not parse end datetime: $end_str" >&2; exit 1; }

    if [[ "$end_epoch" -le "$start_epoch" ]]; then
        echo "End must be after start." >&2
        exit 1
    fi

    local duration_hours=$(( (end_epoch - start_epoch) / 3600 ))
    if [[ "$duration_hours" -gt "$MAX_OVERRIDE_HOURS" ]]; then
        echo "Override duration (${duration_hours}h) exceeds the max of ${MAX_OVERRIDE_HOURS}h." >&2
        exit 1
    fi

    local kept active_count
    kept="$(prune_and_read)"
    active_count=$(grep -c . <<<"$kept" 2>/dev/null || true)
    active_count="${active_count:-0}"
    if [[ "$active_count" -ge "$MAX_ACTIVE_OVERRIDES" ]]; then
        echo "Already at the max of $MAX_ACTIVE_OVERRIDES active/upcoming overrides. Remove one first." >&2
        cmd_list
        exit 1
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║          SHUTDOWN SCHEDULE OVERRIDE REQUEST                     ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "This suspends the shutdown enforcement you built for yourself during:"
    echo "  $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M') -> $(date -d "@$end_epoch" '+%Y-%m-%d %H:%M') (${duration_hours}h)"
    echo "  Reason: $reason"
    echo ""
    echo "Current overrides:"
    cmd_list
    echo ""
    echo "To confirm this is a deliberate, one-off exception (not just wanting to"
    echo "stay up), type the following phrase exactly:"
    echo ""
    echo "  $CONFIRM_PHRASE"
    echo ""
    read -r -p "> " typed_phrase
    if [[ "$typed_phrase" != "$CONFIRM_PHRASE" ]]; then
        echo "Phrase did not match. Aborting." >&2
        log "ABORTED: confirmation phrase mismatch for window $start_str -> $end_str"
        exit 1
    fi

    echo ""
    echo "Waiting $DELAY_SECONDS seconds before committing (Ctrl+C to cancel)..."
    local i
    for ((i = DELAY_SECONDS; i > 0; i--)); do
        printf "\r  Waiting: %2d seconds remaining..." "$i"
        sleep 1
    done
    echo ""

    local created
    created=$(now_epoch)
    printf '%s|%s|%s|%s\n' "$start_epoch" "$end_epoch" "$created" "$reason" >>"$OVERRIDES_FILE"

    log "ADDED override by $(logname 2>/dev/null || echo unknown) from TTY $(tty 2>/dev/null || echo unknown): $start_str -> $end_str (reason: $reason)"
    echo "✓ Override registered: $(date -d "@$start_epoch" '+%Y-%m-%d %H:%M') -> $(date -d "@$end_epoch" '+%Y-%m-%d %H:%M')"
}

case "${1:-}" in
    add)
        shift
        cmd_add "$@"
        ;;
    list)
        cmd_list
        ;;
    remove)
        shift
        cmd_remove "$@"
        ;;
    *)
        echo "Shutdown Override Manager"
        echo "Usage: $0 {add|list|remove}"
        echo ""
        echo "  add '<start>' '<end>' <reason>   Register a time-boxed exception"
        echo "  list                              Show active/upcoming overrides"
        echo "  remove <index>                    Cancel an override (no friction)"
        echo ""
        cmd_list
        ;;
esac
EOF

	chmod +x "$manager_script"
	echo "✓ Created override manager: $manager_script"
	echo "✓ Overrides file: $overrides_file (root-only)"
	echo "✓ Override log: $log_file"
}
