#!/bin/bash
# Visual PC Startup Monitor Status Display
# Shows a nice visual representation of the monitoring status and schedule

# Color codes for visual display
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# Unicode symbols for visual elements
CHECK="✓"
CROSS="✗"
WARNING="⚠️"
CLOCK="🕐"
CALENDAR="📅"
COMPUTER="💻"
BELL="🔔"

# Function to draw a box around text
draw_box() {
  local text="$1"
  local width=${#text}
  local padding=2
  local total_width=$((width + padding * 2))

  # Top border
  printf "┌"
  printf "─%.0s" $(seq 1 $total_width)
  printf "┐\n"

  # Content with padding
  printf "│%*s%s%*s│\n" $padding "" "$text" $padding ""

  # Bottom border
  printf "└"
  printf "─%.0s" $(seq 1 $total_width)
  printf "┘\n"
}

# Function to show current day status
show_day_status() {
  local day_of_week
  day_of_week=$(date +%u)

  printf '%s%s Day Status%s\n' "$BLUE" "$CALENDAR" "$NC"
  printf '═══════════════\n'

  # Show all days with status
  local days=("Monday" "Tuesday" "Wednesday" "Thursday" "Friday" "Saturday" "Sunday")
  local monitored=(1 0 0 0 1 1 1) # 1=monitored, 0=not monitored

  for i in {0..6}; do
    local day_num=$((i + 1))
    if [[ $day_num -eq 7 ]]; then day_num=0; fi # Sunday is 0 in some contexts

    if [[ ${monitored[$i]} -eq 1 ]]; then
      if [[ $day_of_week -eq $((i + 1)) ]] || [[ $day_of_week -eq 7 && $i -eq 6 ]]; then
        printf '%s%s %s (TODAY - MONITORED)%s\n' "$GREEN" "$CHECK" "${days[$i]}" "$NC"
      else
        printf '%s%s %s (monitored)%s\n' "$CYAN" "$CHECK" "${days[$i]}" "$NC"
      fi
    else
      if [[ $day_of_week -eq $((i + 1)) ]]; then
        printf '%s○ %s (TODAY - not monitored)%s\n' "$GRAY" "${days[$i]}" "$NC"
      else
        printf '%s○ %s%s\n' "$GRAY" "${days[$i]}" "$NC"
      fi
    fi
  done

  printf "\n"
}

# Function to show time window status
show_time_status() {
  local current_hour current_minute current_hour_num
  current_hour=$(date +%H)
  current_minute=$(date +%M)
  current_hour_num=$((10#$current_hour))

  printf '%s%s Time Window Status%s\n' "$YELLOW" "$CLOCK" "$NC"
  printf '═══════════════════════\n'

  # Show 24-hour timeline with window highlighted
  printf 'Timeline (24-hour format):\n'
  printf '00 01 02 03 04 '
  printf '%s05 06 07%s ' "$GREEN" "$NC"
  printf '08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23\n'
  printf '               '
  printf '%s▲─────▲%s\n' "$GREEN" "$NC"
  printf '               '
  printf '%sExpected Window%s\n' "$GREEN" "$NC"

  # Current time indicator
  printf '\nCurrent time: %s%02d:%s%s\n' "$WHITE" "$current_hour_num" "$current_minute" "$NC"

  if [[ $current_hour_num -ge 5 && $current_hour_num -lt 8 ]]; then
    printf 'Status: %s%s Within expected window (5AM-8AM)%s\n' "$GREEN" "$CHECK" "$NC"
  else
    printf 'Status: %s○ Outside expected window%s\n' "$YELLOW" "$NC"
  fi

  printf '\n'
}

# Function to show boot time analysis
show_boot_analysis() {
  printf '%s%s Boot Time Analysis%s\n' "$PURPLE" "$COMPUTER" "$NC"
  printf '═══════════════════════\n'

  # Get boot time
  local uptime_seconds boot_time boot_date boot_time_only boot_hour boot_hour_num today
  uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2> /dev/null || echo "0")
  boot_time=$(date -d "@$(($(date +%s) - uptime_seconds))" +"%Y-%m-%d %H:%M:%S")
  boot_date=$(echo "$boot_time" | cut -d' ' -f1)
  boot_time_only=$(echo "$boot_time" | cut -d' ' -f2)
  boot_hour=$(echo "$boot_time_only" | cut -d':' -f1)
  boot_hour_num=$((10#$boot_hour))
  today=$(date +%Y-%m-%d)

  printf 'System boot time: %s%s%s\n' "$WHITE" "$boot_time" "$NC"

  if [[ $boot_date == "$today" ]]; then
    printf 'Boot date: %s%s Today%s\n' "$GREEN" "$CHECK" "$NC"

    if [[ $boot_hour_num -ge 5 && $boot_hour_num -lt 8 ]]; then
      printf 'Boot window: %s%s Within expected window (5AM-8AM)%s\n' "$GREEN" "$CHECK" "$NC"
      printf 'Status: %s%s COMPLIANT%s\n' "$GREEN" "$CHECK" "$NC"
    else
      printf 'Boot window: %s%s Outside expected window%s\n' "$RED" "$CROSS" "$NC"
      printf 'Status: %s%s NON-COMPLIANT%s\n' "$RED" "$WARNING" "$NC"
    fi
  else
    printf 'Boot date: %s○ Not today (%s)%s\n' "$YELLOW" "$boot_date" "$NC"
    printf 'Status: %s○ System was not booted today%s\n' "$YELLOW" "$NC"
  fi

  printf '\n'
}

# Function to show monitoring system status
show_system_status() {
  printf '%s%s Monitoring System%s\n' "$CYAN" "$BELL" "$NC"
  printf '═══════════════════════\n'

  # Check if timer exists and is enabled
  if systemctl is-enabled pc-startup-monitor.timer &> /dev/null; then
    printf 'Service: %s%s ENABLED%s\n' "$GREEN" "$CHECK" "$NC"

    if systemctl is-active pc-startup-monitor.timer &> /dev/null; then
      printf 'Timer: %s%s ACTIVE%s\n' "$GREEN" "$CHECK" "$NC"
    else
      printf 'Timer: %s%s INACTIVE%s\n' "$RED" "$CROSS" "$NC"
    fi

    # Show next check time
    local next_check
    next_check=$(systemctl list-timers pc-startup-monitor.timer --no-pager 2> /dev/null | grep pc-startup-monitor | awk '{print $1, $2, $3}' || echo "Not scheduled")
    printf 'Next check: %s%s%s\n' "$WHITE" "$next_check" "$NC"

  else
    printf 'Service: %s%s NOT ENABLED%s\n' "$RED" "$CROSS" "$NC"
    printf 'Timer: %s%s NOT ACTIVE%s\n' "$RED" "$CROSS" "$NC"
  fi

  printf '\n'
}

# Function to show overall compliance status
show_compliance_overview() {
  local day_of_week current_hour current_hour_num
  day_of_week=$(date +%u)
  current_hour=$(date +%H)
  current_hour_num=$((10#$current_hour))

  # Check if today is monitored
  local is_monitored=false
  if [[ $day_of_week == "1" ]] || [[ $day_of_week == "5" ]] || [[ $day_of_week == "6" ]] || [[ $day_of_week == "7" ]]; then
    is_monitored=true
  fi

  printf '%s' "$WHITE"
  draw_box "COMPLIANCE OVERVIEW"
  printf '%s\n' "$NC"

  if [[ $is_monitored == true ]]; then
    printf 'Today: %s%s Monitored day%s\n' "$GREEN" "$CHECK" "$NC"

    # Check current compliance
    if [[ $current_hour_num -ge 5 && $current_hour_num -lt 8 ]]; then
      printf 'Current status: %s%s PC is on during expected window%s\n' "$GREEN" "$CHECK" "$NC"
      printf 'Action needed: %sNone - currently compliant%s\n' "$GREEN" "$NC"
    else
      # Check if booted in window
      local uptime_seconds boot_time boot_date boot_hour boot_hour_num today
      uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2> /dev/null || echo "0")
      boot_time=$(date -d "@$(($(date +%s) - uptime_seconds))" +"%Y-%m-%d %H:%M:%S")
      boot_date=$(echo "$boot_time" | cut -d' ' -f1)
      boot_hour=$(echo "$boot_time" | cut -d' ' -f2 | cut -d':' -f1)
      boot_hour_num=$((10#$boot_hour))
      today=$(date +%Y-%m-%d)

      if [[ $boot_date == "$today" ]] && [[ $boot_hour_num -ge 5 && $boot_hour_num -lt 8 ]]; then
        printf 'Current status: %s%s PC was booted in expected window%s\n' "$GREEN" "$CHECK" "$NC"
        printf 'Action needed: %sNone - compliant%s\n' "$GREEN" "$NC"
      else
        printf 'Current status: %s%s PC was NOT booted in expected window%s\n' "$RED" "$WARNING" "$NC"
        printf 'Action needed: %sWarning will be shown at 8:30 AM%s\n' "$YELLOW" "$NC"
      fi
    fi
  else
    printf 'Today: %s○ Not a monitored day%s\n' "$GRAY" "$NC"
    printf 'Current status: %sNo monitoring required%s\n' "$GRAY" "$NC"
    printf 'Action needed: %sNone%s\n' "$GRAY" "$NC"
  fi

  printf '\n'
}

# Function to show recent activity
show_recent_activity() {
  printf '%s📋 Recent Activity%s\n' "$GRAY" "$NC"
  printf '════════════════\n'

  # Show last 5 log entries
  local logs
  logs=$(journalctl -t pc-startup-monitor --no-pager -n 5 --output=short 2> /dev/null || echo "No logs found")

  if [[ $logs == "No logs found" ]]; then
    printf '%sNo recent monitoring activity%s\n' "$GRAY" "$NC"
  else
    echo "$logs" | while IFS= read -r line; do
      if [[ $line == *"WARNING"* ]]; then
        printf '%s%s%s\n' "$RED" "$line" "$NC"
      elif [[ $line == *"compliance OK"* ]]; then
        printf '%s%s%s\n' "$GREEN" "$line" "$NC"
      else
        printf '%s%s%s\n' "$GRAY" "$line" "$NC"
      fi
    done
  fi

  printf '\n'
}

# Main display function
main() {
  clear

  # Header
  printf '%s' "$BLUE"
  draw_box "PC STARTUP MONITOR - VISUAL STATUS"
  printf '%s\n\n' "$NC"

  local current_datetime system_uptime
  current_datetime=$(date)
  system_uptime=$(uptime -p)
  printf '%sCurrent Date/Time: %s%s\n' "$WHITE" "$current_datetime" "$NC"
  printf '%sSystem Uptime: %s%s\n\n' "$WHITE" "$system_uptime" "$NC"

  # Show all status sections
  show_day_status
  show_time_status
  show_boot_analysis
  show_system_status
  show_compliance_overview
  show_recent_activity

  # Footer with commands
  printf '%s═══════════════════════════════════════════════════════════════%s\n' "$BLUE" "$NC"
  printf '%sCommands:%s\n' "$WHITE" "$NC"
  printf '  %s%s%s  - Show system status\n' "$CYAN" "sudo pc-startup-monitor-manager.sh status" "$NC"
  printf '  %s%s%s    - Test monitor now\n' "$CYAN" "sudo pc-startup-monitor-manager.sh test" "$NC"
  printf '  %s%s%s    - View detailed logs\n' "$CYAN" "sudo pc-startup-monitor-manager.sh logs" "$NC"
  printf '  %s%s%s                                      - Show this visual status\n' "$CYAN" "$0" "$NC"
  printf '%s═══════════════════════════════════════════════════════════════%s\n' "$BLUE" "$NC"
}

# Run main function
main "$@"
