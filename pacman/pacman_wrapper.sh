#!/bin/bash
# filepath: pacman-wrapper.sh
# A helpful wrapper for Arch Linux's pacman package manager

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

PACMAN_BIN="/usr/bin/pacman"
MAKEPKG_CAPPED_BIN="/usr/local/bin/makepkg_capped"

declare -a BLOCKED_KEYWORDS_LIST=()
declare -a WHITELISTED_NAMES_LIST=()
declare -a GREYLISTED_KEYWORDS_LIST=()
POLICY_LISTS_LOADED=0
INTEGRITY_DIR="/var/lib/pacman-wrapper"
INTEGRITY_FILE="${INTEGRITY_DIR}/policy.sha256"

# Verify integrity of policy files
verify_policy_integrity() {
	if [[ ! -f $INTEGRITY_FILE ]]; then
		echo -e "${RED}SECURITY WARNING: Policy integrity file missing!${NC}" >&2
		echo -e "${RED}The pacman wrapper may have been tampered with.${NC}" >&2
		echo -e "${RED}Please reinstall the wrapper using: sudo install_pacman_wrapper.sh${NC}" >&2
		return 1
	fi

	local script_dir
	script_dir="$(dirname "$(readlink -f "$0")")"
	local blocked_file="$script_dir/pacman_blocked_keywords.txt"
	local greylist_file="$script_dir/pacman_greylist.txt"
	local whitelist_file="$script_dir/pacman_whitelist.txt"

	# Verify checksums
	local failed=0
	while IFS= read -r line; do
		local expected_hash expected_file
		expected_hash=$(echo "$line" | awk '{print $1}')
		expected_file=$(echo "$line" | awk '{print $2}')

		if [[ -f $expected_file ]]; then
			local actual_hash
			actual_hash=$(sha256sum "$expected_file" 2>/dev/null | awk '{print $1}')
			if [[ $actual_hash != "$expected_hash" ]]; then
				echo -e "${RED}SECURITY WARNING: Policy file integrity check failed for $expected_file${NC}" >&2
				failed=1
			fi
		fi
	done <"$INTEGRITY_FILE"

	if [[ $failed -eq 1 ]]; then
		echo -e "${RED}CRITICAL: Policy files have been tampered with!${NC}" >&2
		echo -e "${RED}This could be an attempt to bypass security restrictions.${NC}" >&2
		echo -e "${RED}Wrapper operation DENIED. Please reinstall using: sudo install_pacman_wrapper.sh${NC}" >&2
		return 1
	fi

	return 0
}

# shellcheck disable=SC2329 # invoked indirectly, see is_blocked_package_name/is_greylisted_package_name callers below
load_policy_lists() {
	if [[ $POLICY_LISTS_LOADED -eq 1 ]]; then
		return
	fi

	local script_dir
	script_dir="$(dirname "$(readlink -f "$0")")"
	local blocked_file="$script_dir/pacman_blocked_keywords.txt"
	local whitelist_file="$script_dir/pacman_whitelist.txt"
	local greylist_file="$script_dir/pacman_greylist.txt"

	read_policy_list_file() {
		local file_path="$1"
		local -n target_array="$2"
		local line=""

		target_array=()
		while IFS= read -r line || [[ -n $line ]]; do
			line="${line%$'\r'}"
			if [[ $line =~ ^[[:space:]]*(#|$) ]]; then
				continue
			fi
			target_array+=("${line,,}")
		done < "$file_path"
	}

	if [[ -f $blocked_file ]]; then
		read_policy_list_file "$blocked_file" BLOCKED_KEYWORDS_LIST
	else
		BLOCKED_KEYWORDS_LIST=()
		echo -e "${YELLOW}Warning:${NC} Missing blocked keywords file at $blocked_file" >&2
	fi

	if [[ -f $whitelist_file ]]; then
		read_policy_list_file "$whitelist_file" WHITELISTED_NAMES_LIST
	else
		WHITELISTED_NAMES_LIST=()
	fi

	if [[ -f $greylist_file ]]; then
		read_policy_list_file "$greylist_file" GREYLISTED_KEYWORDS_LIST
	else
		GREYLISTED_KEYWORDS_LIST=()
	fi

	POLICY_LISTS_LOADED=1
}
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
		"$real_home/testsAndMisc/linux_configuration/scripts/periodic_background/setup_periodic_system.sh"
		"$real_home/linux_configuration/scripts/periodic_background/setup_periodic_system.sh"
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

# Function to display help
function show_help() {
	echo -e "${BOLD}Pacman Wrapper Help${NC}"
	echo "This wrapper adds helpful features while preserving all pacman functionality."
	echo ""
	echo "Additional commands:"
	echo "  --help-wrapper    Show this help message"
	echo "  --makepkg-capped  Run makepkg in a constrained systemd user scope"
	echo "                   (forward remaining args to makepkg)"
}

run_makepkg_capped() {
	if [[ ! -x $MAKEPKG_CAPPED_BIN ]]; then
		echo -e "${RED}makepkg capped wrapper not found at ${MAKEPKG_CAPPED_BIN}${NC}" >&2
		echo -e "${YELLOW}Run install_pacman_wrapper.sh to install it.${NC}" >&2
		return 1
	fi

	if [[ $EUID -eq 0 && -n ${SUDO_USER:-} ]]; then
		exec sudo -u "$SUDO_USER" "$MAKEPKG_CAPPED_BIN" "$@"
	fi

	exec "$MAKEPKG_CAPPED_BIN" "$@"
}

# Function to display a message before executing
function display_operation() {
	case "$1" in
	-S)
		echo -e "${BLUE}Installing packages...${NC}" >&2
		;;
	-Sy)
		echo -e "${BLUE}Installing packages...${NC}" >&2
		;;
	-S\ *)
		echo -e "${BLUE}Installing packages...${NC}" >&2
		;;
	-Syu | -Syyu)
		echo -e "${BLUE}Updating system...${NC}" >&2
		;;
	-R)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-Rs)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-Rns)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-R\ *)
		echo -e "${YELLOW}Removing packages...${NC}" >&2
		;;
	-Ss)
		echo -e "${CYAN}Searching for packages...${NC}" >&2
		;;
	-Ss\ *)
		echo -e "${CYAN}Searching for packages...${NC}" >&2
		;;
	-Q)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Qs)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Qi)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Ql)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-Q\ *)
		echo -e "${CYAN}Querying package database...${NC}" >&2
		;;
	-U)
		echo -e "${BLUE}Installing local packages...${NC}" >&2
		;;
	-U\ *)
		echo -e "${BLUE}Installing local packages...${NC}" >&2
		;;
	-Scc)
		echo -e "${YELLOW}Cleaning package cache...${NC}" >&2
		;;
	*)
		echo -e "${CYAN}Executing pacman command...${NC}" >&2
		;;
	esac
}

# Helper: return 0 if the given package name is blocked by policy
# shellcheck disable=SC2329 # invoked indirectly by name (remove_installed_packages_matching, check_install_for)
function is_blocked_package_name() {
	load_policy_lists
	local normalized="${1,,}"

	for allowed in "${WHITELISTED_NAMES_LIST[@]}"; do
		if [[ $normalized == "$allowed" ]]; then
			return 1
		fi
	done

	for keyword in "${BLOCKED_KEYWORDS_LIST[@]}"; do
		if [[ $normalized == *"$keyword"* ]]; then
			return 0
		fi
	done

	return 1
}

# Helper: return 0 if the given package name is greylisted (challenge required)
# shellcheck disable=SC2329 # invoked indirectly by name (remove_installed_packages_matching, check_install_for)
function is_greylisted_package_name() {
	load_policy_lists
	local normalized="${1,,}"

	for keyword in "${GREYLISTED_KEYWORDS_LIST[@]}"; do
		if [[ $normalized == *"$keyword"* ]]; then
			return 0
		fi
	done

	return 1
}

current_day_of_week() {
	printf '%(%u)T\n' -1
}

current_hour_24() {
	printf '%(%H)T\n' -1
}

current_day_name() {
	printf '%(%A)T\n' -1
}

# Stale pacman DB-lock detection/handling (get_lock_holders,
# check_and_handle_db_lock) plus has_noconfirm_flag and current_epoch now live in
# the shared pacman_lock_lib.sh, sourced after the integrity check below. This is
# the single source of truth shared with makepkg_wrapper.sh.

# Generic function to remove installed packages matching a filter
# Args: check_function label_prefix
function remove_installed_packages_matching() {
	local check_function="$1"
	local label="$2"

	mapfile -t installed_names < <("$PACMAN_BIN" -Qq 2>/dev/null)
	local to_remove=()
	for name in "${installed_names[@]}"; do
		if "$check_function" "$name"; then
			to_remove+=("$name")
		fi
	done

	if [[ ${#to_remove[@]} -eq 0 ]]; then
		return 0
	fi

	echo -e "${YELLOW}${label} cleanup:${NC} Removing packages: ${BOLD}${to_remove[*]}${NC}" >&2
	"$PACMAN_BIN" -Rns --noconfirm "${to_remove[@]}"
	local rc=$?
	if [[ $rc -ne 0 ]]; then
		echo -e "${RED}${label} cleanup removal failed with exit code ${rc}.${NC}" >&2
	else
		echo -e "${GREEN}${label} cleanup removal completed for: ${to_remove[*]}${NC}" >&2
	fi
	return $rc
}

# Cleanup: remove any installed blocked packages
function remove_installed_blocked_packages() {
	remove_installed_packages_matching is_blocked_package_name "Policy"
}

# Cleanup: remove any installed greylisted packages
function remove_installed_greylisted_packages() {
	remove_installed_packages_matching is_greylisted_package_name "Greylist"
}

# Helper: Check if this is an install command and run a filter on each package name
# Usage: check_install_for filter_func "$@"
# Returns 0 if filter_func matches any package
function check_install_for() {
	local filter_func="$1"
	shift
	# Check if the command is an installation command
	if [[ ${1:-} == "-S" || ${1:-} == "-Sy" || ${1:-} == "-Syu" || ${1:-} == "-Syyu" || ${1:-} == "-U" ]]; then
		for arg in "$@"; do
			# Strip repository prefix if present (like extra/ or community/)
			local package_name="${arg##*/}"
			if "$filter_func" "$package_name"; then
				return 0
			fi
		done
	fi
	return 1
}

# Function to check if user is trying to install packages that are always blocked
function check_for_always_blocked() {
	check_install_for is_blocked_package_name "$@"
}

# Helper to check if a package name is steam
# shellcheck disable=SC2329 # invoked indirectly by name (check_install_for)
function is_steam_package() {
	[[ $1 == "steam" ]]
}

# Function to check if user is trying to install steam (challenge-eligible package)
function check_for_steam() {
	check_install_for is_steam_package "$@"
}

# Function to check if current day is a weekday (after 4PM Friday until midnight Sunday)
function is_weekday() {
	local day_of_week
	day_of_week=$(current_day_of_week) # %u gives 1-7 (Monday is 1, Sunday is 7)
	local hour
	hour=$(current_hour_24) # %H gives hour in 24-hour format (00-23)

	# Monday through Thursday are always weekdays
	if [[ $day_of_week -ge 1 && $day_of_week -le 4 ]]; then
		return 0 # Is weekday
	# Friday before 4PM is weekday, after 4PM is weekend
	elif [[ $day_of_week -eq 5 ]]; then
		if [[ $hour -lt 14 ]]; then
			return 0 # Is weekday (Friday before 4PM)
		else
			return 1 # Is weekend (Friday after 4PM)
		fi
	# Saturday and Sunday are weekend
	else
		return 1 # Is weekend
	fi
}

# Unified word unscrambling challenge function
# Args: challenge_name word_length words_count timeout_seconds initial_delay_max post_delay_min post_delay_range
function run_word_challenge() {
	local challenge_name="$1"
	local word_length="$2"
	local words_count="$3"
	local timeout_seconds="$4"
	local initial_delay_max="${5:-20}"
	local post_delay_min="${6:-0}"
	local post_delay_range="${7:-20}"

	echo -e "${YELLOW}${challenge_name} challenge will begin shortly...${NC}"

	# Initial delay
	local sleep_duration=$((RANDOM % initial_delay_max))
	sleep "$sleep_duration"

	# Load words file
	local script_dir words_file
	script_dir="$(dirname "$(readlink -f "$0")")"
	words_file="$script_dir/words.txt"

	if [[ ! -f $words_file ]]; then
		echo -e "${RED}Error: words.txt file not found at $words_file${NC}"
		return 1
	fi

	echo -e "${CYAN}Challenge: Words with ${word_length} letters${NC}"

	# Load random words of specified length
	local -a selected_words
	mapfile -t selected_words < <(grep -E "^[a-zA-Z]{$word_length}$" "$words_file" | shuf -n "$words_count")

	if [[ ${#selected_words[@]} -lt $words_count ]]; then
		echo -e "${RED}Warning: Could only find ${#selected_words[@]} words of length $word_length.${NC}"
		words_count=${#selected_words[@]}
		if [[ $words_count -eq 0 ]]; then
			echo -e "${RED}Error: No words of length $word_length found in $words_file${NC}"
			return 1
		fi
	fi

	# Convert to uppercase
	for i in "${!selected_words[@]}"; do
		selected_words[i]=$(echo "${selected_words[i]}" | tr '[:lower:]' '[:upper:]')
	done

	echo -e "${CYAN}Here are ${words_count} random words. Remember them:${NC}"

	# Display words in grid
	for ((i = 0; i < words_count; i++)); do
		printf "${BLUE}%-15s${NC}" "${selected_words[i]}"
		if (((i + 1) % 4 == 0)); then
			echo ""
		fi
	done

	# Select and scramble a word
	local target_index target_word scrambled_word
	target_index=$((RANDOM % words_count))
	target_word="${selected_words[target_index]}"
	scrambled_word=$(echo "$target_word" | fold -w1 | shuf | tr -d '\n')

	if [[ $scrambled_word == "$target_word" ]]; then
		scrambled_word=$(echo "$target_word" | rev)
	fi

	echo -e "\n${YELLOW}One of those words has been scrambled to:${NC} ${CYAN}$scrambled_word${NC}"
	echo -e "${YELLOW}Unscramble the word to proceed (you have $timeout_seconds seconds):${NC}"

	# Timer display background process
	(
		local start_time current_time elapsed remaining
		start_time=$(current_epoch)
		while true; do
			current_time=$(current_epoch)
			elapsed=$((current_time - start_time))
			remaining=$((timeout_seconds - elapsed))
			if [[ $remaining -le 0 ]]; then
				echo -ne "\r${YELLOW}Time remaining: 0 seconds${NC}    "
				break
			fi
			echo -ne "\r${YELLOW}Time remaining: ${remaining} seconds${NC}    "
			sleep 1
		done
	) &
	local display_pid=$!

	# Read input with timeout
	local user_input read_status
	read -t "$timeout_seconds" -r user_input
	read_status=$?

	kill "$display_pid" 2>/dev/null
	wait "$display_pid" 2>/dev/null
	echo

	if [[ $read_status -ne 0 ]]; then
		echo -e "${RED}Time's up! Challenge failed. The correct word was '$target_word'.${NC}"
		return 1
	fi

	user_input=$(echo "$user_input" | tr '[:lower:]' '[:upper:]' | xargs)

	if [[ $user_input == "$target_word" ]]; then
		echo -e "${GREEN}Correct! Proceeding with installation...${NC}"
		local post_challenge_sleep=$((RANDOM % post_delay_range + post_delay_min))
		[[ $post_challenge_sleep -gt 0 ]] && sleep "$post_challenge_sleep"
		return 0
	else
		echo -e "${RED}Incorrect answer. Installation aborted. The correct word was '$target_word'.${NC}"
		return 1
	fi
}

# Function to prompt for solving a word unscrambling challenge (only for steam)
function prompt_for_steam_challenge() {
	echo -e "${YELLOW}WARNING: You are trying to install Steam.${NC}"

	# Check if it's a weekday and block completely
	if is_weekday; then
		local day_name
		day_name=$(current_day_name)
		echo -e "${RED}Steam installation BLOCKED: Steam cannot be installed on weekdays.${NC}"
		echo -e "${RED}Today is $day_name. Please try again on the weekend (Saturday or Sunday).${NC}"
		return 1
	fi

	# word_length=5, words_count=160, timeout=60s, initial_delay=20, post_delay=0-20
	run_word_challenge "Weekend Steam" 5 160 60 20 0 20
}

function check_for_greylisted() {
	check_install_for is_greylisted_package_name "$@"
}

# Function to prompt for solving a word unscrambling challenge (for greylisted packages - always active)
function prompt_for_greylist_challenge() {
	echo -e "${YELLOW}WARNING: You are trying to install a greylisted package.${NC}"

	# word_length=6, words_count=120, timeout=90s, initial_delay=30, post_delay=15-35
	run_word_challenge "Greylist" 6 120 90 30 15 20
}

# Check for wrapper-specific commands
if [[ $1 == "--help-wrapper" ]]; then
	show_help
	exit 0
fi

if [[ ${1:-} == "--makepkg-capped" ]]; then
	shift
	run_makepkg_capped "$@"
fi

# ---------------------------------------------------------------------------
# Fast pass-through for unprivileged, sandboxed and read-only invocations.
#
# makepkg/yay invoke pacman dozens of times for dependency resolution and
# metadata (e.g. `pacman -T`, `-Qi`, `-Qq`) — as a non-root user and inside a
# fakeroot build sandbox. Policy enforcement, service checks and package
# cleanup only make sense for a genuine privileged transaction (root running
# -S/-U/-R/-Syu ...), so for everything else we exec the real pacman directly.
# This avoids the root-only policy-file read ("policy.sha256: Permission
# denied"), the D-Bus "Failed to connect to system scope bus" errors from
# systemctl inside the build sandbox, and the per-call log spam during builds.
#
# Note: inside fakeroot $EUID reports 0 (libfakeroot intercepts geteuid), so it
# is the FAKEROOTKEY check — not the EUID check — that catches in-sandbox calls.
# ---------------------------------------------------------------------------
if [[ $EUID -ne 0 || -n ${FAKEROOTKEY:-} ]] || ! needs_unlock "$@"; then
	exec "$PACMAN_BIN" "$@"
fi

# CRITICAL: Verify policy file integrity before any operations
if ! verify_policy_integrity; then
	exit 1
fi

# Load shared stale-lock helpers (get_lock_holders, check_and_handle_db_lock,
# has_noconfirm_flag, current_epoch), AFTER integrity verification so a tampered
# lib (listed in the integrity manifest) is caught before it is sourced. Sourced
# here — past the fast-path — so build-time non-root calls skip it entirely.
_WRAPPER_DIR="$(dirname "$(readlink -f "$0")")"
if [[ -r "$_WRAPPER_DIR/pacman_lock_lib.sh" ]]; then
	# shellcheck source=pacman_lock_lib.sh
	source "$_WRAPPER_DIR/pacman_lock_lib.sh"
else
	# Fail open: a missing lib must not brick pacman (you'd need pacman to
	# reinstall it). Skip stale-lock handling with safe no-op fallbacks.
	echo -e "${YELLOW}Warning: pacman_lock_lib.sh missing; stale-lock handling disabled.${NC}" >&2
	check_and_handle_db_lock() { return 0; }
	current_epoch() { printf '%(%s)T\n' -1; }
fi

# Before any pacman action, ensure maintenance services exist
ensure_periodic_maintenance

# PROACTIVE CLEANUP: Always check and remove blocked packages at startup
# This catches packages that were installed before the wrapper or via other means
echo -e "${CYAN}Checking for blocked packages...${NC}" >&2
remove_installed_blocked_packages "$@"
remove_installed_greylisted_packages "$@"

# Check for always blocked packages first (highest priority)
if check_for_always_blocked "$@"; then
	echo -e "${RED}Installation BLOCKED: This package is permanently restricted and cannot be installed.${NC}"
	echo -e "${RED}Package installation has been denied by system policy.${NC}"
	# Regardless of the attempted action, enforce cleanup of any installed blocked packages
	remove_installed_blocked_packages "$@"
	exit 1
fi

# Check for steam (challenge-eligible package)
if check_for_steam "$@"; then
	if ! prompt_for_steam_challenge; then
		exit 1
	fi
fi

# Check for greylisted packages (challenge-eligible)
if check_for_greylisted "$@"; then
	if ! prompt_for_greylist_challenge; then
		exit 1
	fi
fi

# Display operation
display_operation "$1"

# Echo the command that's about to be executed
echo -e "${GREEN}Executing:${NC} $PACMAN_BIN $*" >&2

# Record start time for statistics
start_time=$(current_epoch)

# Handle a possible stale DB lock before executing
if ! check_and_handle_db_lock "$@"; then
	exit 1
fi

manual_guard_lib_fallback=0

# Execute the real pacman command (with guard-lib fallback handling)
if should_use_wrapper_guard_lib_fallback "$@"; then
	pre_unlock_guard_lib
	manual_guard_lib_fallback=1
fi

"$PACMAN_BIN" "$@"
exit_code=$?

if [[ $manual_guard_lib_fallback -eq 1 ]]; then
	post_relock_guard_lib
fi

# Record end time for statistics
end_time=$(current_epoch)
duration=$((end_time - start_time))

# Display results
if [ $exit_code -eq 0 ]; then
	echo -e "${GREEN}Command completed successfully in ${duration}s.${NC}" >&2
else
	echo -e "${RED}Command failed with exit code ${exit_code}.${NC}" >&2
fi

# After any operation, remove installed blocked packages as part of policy enforcement
remove_installed_blocked_packages "$@"

# Also remove installed greylisted packages
remove_installed_greylisted_packages "$@"

# Auto-install LeechBlock if a browser is detected
auto_install_leechblock() {
	# Only check after install operations
	if [[ -z ${1:-} ]] || [[ $1 != "-S"* && $1 != "-U"* ]]; then
		return 0
	fi

	# List of browser packages to check for
	local browsers=("firefox" "librewolf" "chromium" "brave" "vivaldi" "google-chrome" "ungoogled-chromium")
	local browser_found=0

	for browser in "${browsers[@]}"; do
		if "$PACMAN_BIN" -Qq "$browser" 2>/dev/null; then
			browser_found=1
			break
		fi
	done

	if [[ $browser_found -eq 0 ]]; then
		return 0
	fi

	# Find the LeechBlock installer
	local script_dir
	script_dir="$(dirname "$(readlink -f "$0")")"
	local leechblock_installer=""

	if [[ -f "/usr/local/share/digital_wellbeing/install_leechblock.sh" ]]; then
		leechblock_installer="/usr/local/share/digital_wellbeing/install_leechblock.sh"
	elif [[ -f "$script_dir/../install_leechblock.sh" ]]; then
		leechblock_installer="$script_dir/../install_leechblock.sh"
	fi

	if [[ -z $leechblock_installer ]]; then
		echo -e "${YELLOW}Browser detected but LeechBlock installer not found.${NC}" >&2
		return 0
	fi

	# Check if LeechBlock is already installed (by looking for the extension directory)
	if [[ -d "$HOME/.local/share/leechblockng" ]]; then
		return 0
	fi

	echo -e "${CYAN}Browser detected. Installing LeechBlock extension for website blocking...${NC}" >&2

	# Run the LeechBlock installer (as current user, not root)
	if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
		sudo -u "$SUDO_USER" bash "$leechblock_installer" --install-firefox 2>&1 || {
			echo -e "${YELLOW}LeechBlock auto-install failed. Please install manually:${NC}" >&2
			echo -e "${YELLOW}  $leechblock_installer${NC}" >&2
		}
	else
		bash "$leechblock_installer" --install-firefox 2>&1 || {
			echo -e "${YELLOW}LeechBlock auto-install failed. Please install manually:${NC}" >&2
			echo -e "${YELLOW}  $leechblock_installer${NC}" >&2
		}
	fi
}

auto_install_leechblock "$@"

# If VirtualBox is installed, automatically remove all VMs
auto_remove_virtualbox_vms() {
	# Check if VBoxManage is available
	if ! command -v VBoxManage &>/dev/null; then
		return 0
	fi

	# Determine real user (wrapper may run as root via sudo)
	local real_user="${SUDO_USER:-$USER}"

	# Get list of registered VMs (run as real user since VMs are per-user)
	local vm_list
	vm_list=$(sudo -u "$real_user" VBoxManage list vms 2>/dev/null) || return 0

	if [[ -z $vm_list ]]; then
		return 0
	fi

	echo -e "${RED}═══════════════════════════════════════════════════════${NC}" >&2
	echo -e "${RED}     VIRTUALBOX VMs DETECTED - AUTO-REMOVING           ${NC}" >&2
	echo -e "${RED}═══════════════════════════════════════════════════════${NC}" >&2

	local vm_name
	local success=0
	local failed=0

	while IFS= read -r line; do
		# VBoxManage list vms output format: "VM Name" {uuid}
		vm_name="${line#\"}"
		vm_name="${vm_name%%\"*}"
		if [[ -z $vm_name ]]; then
			continue
		fi

		echo -e "${YELLOW}Removing VM: ${vm_name}${NC}" >&2

		# Power off the VM if it's running
		sudo -u "$real_user" VBoxManage controlvm "$vm_name" poweroff 2>/dev/null || true
		sleep 1

		# Unregister and delete all files
		if sudo -u "$real_user" VBoxManage unregistervm "$vm_name" --delete 2>/dev/null; then
			echo -e "${GREEN}  Removed: ${vm_name}${NC}" >&2
			((++success))
		else
			echo -e "${RED}  Failed to remove: ${vm_name}${NC}" >&2
			((++failed))
		fi
	done <<<"$vm_list"

	echo -e "${CYAN}VM removal complete: ${success} removed, ${failed} failed.${NC}" >&2
}

auto_remove_virtualbox_vms

# Display some helpful tips depending on the operation
if [[ $1 == "-S" || $1 == "-S "* ]] && [ $exit_code -eq 0 ]; then
	echo -e "${CYAN}Tip:${NC} You may need to log out or restart to use some newly installed software."
fi

if [[ $1 == "-Syu" || $1 == "-Syyu" ]] && [ $exit_code -eq 0 ]; then
	echo -e "${CYAN}Tip:${NC} Consider restarting after major updates."
fi

exit $exit_code
