#!/bin/bash
# Smart midnight shutdown check script
# Only shuts down if the current time is actually close to midnight
# Prevents shutdown on boot if system was off during scheduled time

# Get current time components
current_hour=$(date +%H)
current_minute=$(date +%M)
current_time_minutes=$((10#$current_hour * 60 + 10#$current_minute))

# Midnight is 0 minutes (00:00)
# Allow shutdown if we're within 5 minutes of midnight
# This covers 23:55-00:05 range
if [[ $current_time_minutes -le 5 ]] || [[ $current_time_minutes -ge 1435 ]]; then
    echo "$(date): Executing midnight shutdown - current time is within shutdown window"
    logger -t midnight-shutdown "Executing scheduled shutdown at $(date)"
    /usr/bin/systemctl poweroff
else
    echo "$(date): Skipping shutdown - not within midnight window (current: $current_hour:$current_minute)"
    logger -t midnight-shutdown "Skipped shutdown - not within midnight window (current: $current_hour:$current_minute)"
fi
