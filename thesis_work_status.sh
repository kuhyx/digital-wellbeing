#!/bin/bash
# Quick status checker for thesis work tracker
# Shows current work progress and access status

set -euo pipefail

STATE_FILE="/var/lib/thesis-work-tracker/work-time.state"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Check if state file exists
if [[ ! -f $STATE_FILE ]]; then
    echo -e "${RED}Error:${NC} Thesis work tracker is not installed or has not been initialized."
    echo "Install with: sudo scripts/digital_wellbeing/setup_thesis_work_tracker.sh"
    exit 1
fi

# Load state (need sudo to read immutable file)
if [[ $EUID -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

# Temporarily remove immutable to read
sudo chattr -i "$STATE_FILE" 2>/dev/null || true

# Parse state file safely without using source
# Only extract the numeric values we need
TOTAL_WORK_SECONDS=$(grep "^TOTAL_WORK_SECONDS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
STEAM_ACCESS_GRANTED=$(grep "^STEAM_ACCESS_GRANTED=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
CURRENT_SESSION_SECONDS=$(grep "^CURRENT_SESSION_SECONDS=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")
LAST_WORK_SESSION_START=$(grep "^LAST_WORK_SESSION_START=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo "0")

# Validate that values are numeric
if ! [[ $TOTAL_WORK_SECONDS =~ ^[0-9]+$ ]]; then TOTAL_WORK_SECONDS=0; fi
if ! [[ $STEAM_ACCESS_GRANTED =~ ^[01]$ ]]; then STEAM_ACCESS_GRANTED=0; fi
if ! [[ $CURRENT_SESSION_SECONDS =~ ^[0-9]+$ ]]; then CURRENT_SESSION_SECONDS=0; fi
if ! [[ $LAST_WORK_SESSION_START =~ ^[0-9]+$ ]]; then LAST_WORK_SESSION_START=0; fi

# Re-apply immutable
sudo chattr +i "$STATE_FILE" 2>/dev/null || true

# Default values if not set
TOTAL_WORK_SECONDS=${TOTAL_WORK_SECONDS:-0}
STEAM_ACCESS_GRANTED=${STEAM_ACCESS_GRANTED:-0}
CURRENT_SESSION_SECONDS=${CURRENT_SESSION_SECONDS:-0}
LAST_WORK_SESSION_START=${LAST_WORK_SESSION_START:-0}

# Constants (should match tracker script)
WORK_QUOTA_REQUIRED=7200  # 2 hours default

# Calculate values
work_minutes=$((TOTAL_WORK_SECONDS / 60))
work_hours=$((work_minutes / 60))
work_remaining_minutes=$((work_minutes % 60))

quota_minutes=$((WORK_QUOTA_REQUIRED / 60))
quota_hours=$((quota_minutes / 60))
quota_remaining_minutes=$((quota_minutes % 60))

remaining_seconds=$((WORK_QUOTA_REQUIRED - TOTAL_WORK_SECONDS))
if [[ $remaining_seconds -lt 0 ]]; then
    remaining_seconds=0
fi
remaining_minutes=$((remaining_seconds / 60))

session_minutes=$((CURRENT_SESSION_SECONDS / 60))

percentage=$((TOTAL_WORK_SECONDS * 100 / WORK_QUOTA_REQUIRED))
if [[ $percentage -gt 100 ]]; then
    percentage=100
fi

# Display status
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         Bachelor Thesis Work Tracker - Status                 ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Work progress
echo -e "${BOLD}Work Progress:${NC}"
echo -e "  Total work time: ${GREEN}${work_hours}h ${work_remaining_minutes}m${NC}"
echo -e "  Required quota:  ${BLUE}${quota_hours}h ${quota_remaining_minutes}m${NC}"

# Progress bar
echo -n "  Progress: ["
bar_length=40
filled=$((percentage * bar_length / 100))
for ((i=0; i<bar_length; i++)); do
    if [[ $i -lt $filled ]]; then
        echo -n "█"
    else
        echo -n "░"
    fi
done
echo -e "] ${percentage}%"

# Remaining time
if [[ $remaining_minutes -gt 0 ]]; then
    echo -e "  ${YELLOW}Need ${remaining_minutes} more minutes to unlock distractions${NC}"
else
    echo -e "  ${GREEN}✓ Quota met! Keep up the good work!${NC}"
fi
echo ""

# Access status
echo -e "${BOLD}Access Status:${NC}"
if [[ $STEAM_ACCESS_GRANTED -eq 1 ]]; then
    echo -e "  Steam & Distractions: ${GREEN}UNLOCKED${NC} ✓"
else
    echo -e "  Steam & Distractions: ${RED}BLOCKED${NC} ⛔"
fi
echo ""

# Current session
if [[ $LAST_WORK_SESSION_START -ne 0 ]]; then
    echo -e "${BOLD}Current Session:${NC}"
    echo -e "  ${GREEN}Active work session in progress${NC}"
    echo -e "  Session duration: ${session_minutes} minutes"
    echo ""
fi

# Service status
echo -e "${BOLD}Service Status:${NC}"
if systemctl is-active --quiet "thesis-work-tracker@$(logname).service" 2>/dev/null; then
    echo -e "  Tracker daemon: ${GREEN}RUNNING${NC} ✓"
else
    echo -e "  Tracker daemon: ${RED}NOT RUNNING${NC} ⚠"
    echo -e "  ${YELLOW}Start with: sudo systemctl start thesis-work-tracker@\$(whoami).service${NC}"
fi
echo ""

# Useful commands
echo -e "${BOLD}Useful Commands:${NC}"
echo "  • View live logs:     tail -f /var/log/thesis-work-tracker/tracker.log"
echo "  • Service status:     systemctl status thesis-work-tracker@\$(whoami).service"
echo "  • Restart tracker:    sudo systemctl restart thesis-work-tracker@\$(whoami).service"
echo ""
