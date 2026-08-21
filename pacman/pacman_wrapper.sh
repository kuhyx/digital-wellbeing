#!/bin/bash
# filepath: pacman-wrapper.sh
# A helpful wrapper for Arch Linux's pacman package manager

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
# Exported: consumed by pw_ui.sh and pw_cleanup.sh, which are sourced
# separately, so shellcheck cannot see the use without -x.
export BOLD='\033[1m'
NC='\033[0m' # No Color

PACMAN_BIN="/usr/bin/pacman"

# ---------------------------------------------------------------------------
# Libraries. Sourced HERE, at the very top, because the fast path below execs
# real pacman and needs_unlock() — which decides whether to take it — now lives
# in pw_guard.sh. Deployed FLAT beside this script in /usr/local/bin, the same
# shape as pacman_lock_lib.sh and heavy_job_lock.sh; in the repo they sit
# beside it too, so one resolution rule covers both.
#
# FAIL OPEN, deliberately, and unlike every other split in this campaign: this
# file IS /usr/bin/pacman. If a lib goes missing, aborting would leave the
# machine with no working package manager and no way to reinstall the lib. So
# a missing lib degrades to plain pacman with a warning on stderr, which is
# the same choice the existing pacman_lock_lib.sh block below already makes.
#
# The integrity check that guards the POLICY files still runs below, before
# any transaction is allowed through.
# ---------------------------------------------------------------------------
_WRAPPER_DIR="$(dirname "$(readlink -f "$0")")"
for _pw_lib in pw_policy pw_guard pw_ui pw_challenge pw_cleanup; do
	if [[ -r "$_WRAPPER_DIR/${_pw_lib}.sh" ]]; then
		# shellcheck source=/dev/null
		source "$_WRAPPER_DIR/${_pw_lib}.sh"
	fi
done
unset _pw_lib

if ! declare -F needs_unlock >/dev/null || ! declare -F verify_policy_integrity >/dev/null; then
	printf 'Warning: pacman wrapper libraries missing; running pacman unwrapped.\n' >&2
	exec "$PACMAN_BIN" "$@"
fi
# Installed alongside the wrapper by install_pacman_wrapper.sh. Absent on a
# machine that has not run it yet, in which case transactions simply are not
# serialised (see the guarded source below).
HEAVY_JOB_LOCK_LIB="/usr/local/bin/heavy_job_lock.sh"
# Exported: used only by pw_ui.sh (sourced separately).
export MAKEPKG_CAPPED_BIN="/usr/local/bin/makepkg_capped"

# The policy lists and the integrity-file paths are declared in pw_policy.sh,
# the only file that reads or writes them.

# Stale pacman DB-lock detection/handling (get_lock_holders,
# check_and_handle_db_lock) plus has_noconfirm_flag and current_epoch now live in
# the shared pacman_lock_lib.sh, sourced after the integrity check below. This is
# the single source of truth shared with makepkg_wrapper.sh.

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

# Serialise real TRANSACTIONS against builds and coverage runs on this 7.6 GB
# box (see utils/heavy_job_lock.sh). Deliberately scoped by needs_unlock, i.e.
# -S/-U/-R only: read-only queries like `pacman -Q` take no db lock and run
# constantly from background services here, so making those wait behind a
# 20-minute Gradle build would be worse than the contention it avoids.
# with_heavy_lock always fails open, so this can never brick package management.
if [[ -r $HEAVY_JOB_LOCK_LIB ]] && needs_unlock "$@"; then
	# shellcheck source=/dev/null
	source "$HEAVY_JOB_LOCK_LIB"
	with_heavy_lock pacman -- "$PACMAN_BIN" "$@"
else
	"$PACMAN_BIN" "$@"
fi
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

auto_install_leechblock "$@"

auto_remove_virtualbox_vms

# Display some helpful tips depending on the operation
if [[ $1 == "-S" || $1 == "-S "* ]] && [ $exit_code -eq 0 ]; then
	echo -e "${CYAN}Tip:${NC} You may need to log out or restart to use some newly installed software."
fi

if [[ $1 == "-Syu" || $1 == "-Syyu" ]] && [ $exit_code -eq 0 ]; then
	echo -e "${CYAN}Tip:${NC} Consider restarting after major updates."
fi

exit $exit_code
