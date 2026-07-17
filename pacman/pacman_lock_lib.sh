#!/bin/bash
# pacman_lock_lib.sh — shared stale pacman DB-lock handling.
#
# Single source of truth for detecting and clearing an orphaned
# /var/lib/pacman/db.lck. Sourced by BOTH pacman_wrapper.sh and
# makepkg_wrapper.sh so the stale-lock policy lives in exactly one place.
#
# This file only defines functions/vars — it must be *sourced*, never executed.
# It intentionally does NOT enable `set -euo pipefail`: the sourcing script owns
# its own shell options, and toggling them from a library would surprise callers.
#
# Testability: the lock path is taken from $PACMAN_LOCK_FILE (default
# /var/lib/pacman/db.lck) so the shell test harness can point it at a temp file
# instead of the real system lock. Production behaviour is unchanged when the
# variable is unset.

# Guard against double-sourcing (both wrappers may source transitively).
# This file is meant to be sourced, so `return` is the correct exit here.
if [[ -n ${_PACMAN_LOCK_LIB_LOADED:-} ]]; then
	return 0
fi
_PACMAN_LOCK_LIB_LOADED=1

# Colors — only set if the caller has not already defined them, so a wrapper
# that defines its own palette keeps it. Values use literal escape sequences to
# match the callers' `echo -e` style.
: "${RED:=\033[0;31m}"
: "${GREEN:=\033[0;32m}"
: "${YELLOW:=\033[0;33m}"
: "${BLUE:=\033[0;34m}"
: "${CYAN:=\033[0;36m}"
: "${NC:=\033[0m}"

# Lock file location (overridable for tests).
PACMAN_LOCK_FILE="${PACMAN_LOCK_FILE:-/var/lib/pacman/db.lck}"

# Helper: detect if current invocation includes --noconfirm
has_noconfirm_flag() {
	for arg in "$@"; do
		if [[ $arg == "--noconfirm" ]]; then
			return 0
		fi
	done
	return 1
}

# Current unix epoch (bash builtin, no fork).
current_epoch() {
	printf '%(%s)T\n' -1
}

# Helper: get list of PIDs holding a lock file (excluding our own PID)
# Populates the $holders array
get_lock_holders() {
	local lock_file="$1"
	holders=()
	if command -v fuser >/dev/null 2>&1; then
		read -r -a holders <<< "$(fuser "$lock_file" 2>/dev/null || true)"
	elif command -v lsof >/dev/null 2>&1; then
		mapfile -t holders < <(lsof -t "$lock_file" 2>/dev/null || true)
	fi
	# Filter out our own PID
	if [[ ${#holders[@]} -gt 0 ]]; then
		local -a filtered=()
		for pid in "${holders[@]}"; do
			[[ $pid -eq $$ ]] && continue
			filtered+=("$pid")
		done
		holders=("${filtered[@]}")
	fi
}

# Helper: is any real pacman/pamac transaction process running system-wide?
# Unlike fuser on the lock file, pgrep reads /proc/*/comm which is visible across
# users, so an UNPRIVILEGED caller (e.g. this lib running under makepkg, which is
# never root) can still detect a ROOT `pacman -Syu`. This closes the gap where a
# non-root fuser cannot see a root process's open fds and would wrongly conclude
# the lock is orphaned. Trade-off: a (rare) hung/zombie process literally named
# `pacman` will also block removal — erring toward safety over a rare re-hang.
pacman_process_running() {
	pgrep -x pacman >/dev/null 2>&1 && return 0
	pgrep -x pacman.orig >/dev/null 2>&1 && return 0
	pgrep -x pamac >/dev/null 2>&1 && return 0
	return 1
}

# Handle stale pacman database lock if present and no package managers are running.
# Returns 0 if the lock is absent, was cleared, or the caller may proceed.
# Returns 1 if a genuine pacman/pamac transaction (or an un-freeable updater)
# holds the lock, or the user declined to remove it — caller must NOT proceed.
check_and_handle_db_lock() {
	local lock_file="$PACMAN_LOCK_FILE"
	# Quick exit if no lock
	if [[ ! -e $lock_file ]]; then
		return 0
	fi

	# Determine which processes actually have the lock open
	local -a holders=()
	get_lock_holders "$lock_file"

	if [[ ${#holders[@]} -gt 0 ]]; then
		local pac_holder=0
		local gui_holder=0
		for pid in "${holders[@]}"; do
			local comm args lower
			comm=$(ps -p "$pid" -o comm= 2>/dev/null || true)
			args=$(ps -p "$pid" -o args= 2>/dev/null || true)
			lower="${comm,,} ${args,,}"
			if [[ $lower == *" pacman"* || $lower == pacman* || $lower == *"/pacman "* || $lower == *" pamac"* ]]; then
				pac_holder=1
			elif [[ $lower == *packagekit* || $lower == *gnome-software* || $lower == *discover* ]]; then
				gui_holder=1
			fi
		done

		if [[ $pac_holder -eq 1 ]]; then
			echo -e "${RED}Another pacman/pamac transaction is holding the database lock. Try again later.${NC}" >&2
			return 1
		fi

		if [[ $gui_holder -eq 1 ]]; then
			echo -e "${YELLOW}A background software updater is holding the pacman lock. Attempting to stop it...${NC}" >&2
			if command -v systemctl >/dev/null 2>&1; then
				systemctl --quiet stop packagekit.service 2>/dev/null || true
				systemctl --quiet stop packagekit 2>/dev/null || true
			fi
			pkill -x packagekitd 2>/dev/null || true
			pkill -f gnome-software 2>/dev/null || true
			pkill -f discover 2>/dev/null || true
			sleep 1

			# Re-check holders
			get_lock_holders "$lock_file"
			if [[ ${#holders[@]} -gt 0 ]]; then
				echo -e "${RED}Cannot free the pacman lock; another process still holds it. Try again later.${NC}" >&2
				return 1
			fi
		fi
	fi

	# Cross-user safety net: even if fuser (possibly run unprivileged) could not
	# see the holder, refuse to remove the lock while any real pacman/pamac
	# process is running system-wide.
	if pacman_process_running; then
		echo -e "${RED}A pacman/pamac process is running; not removing the database lock. Try again later.${NC}" >&2
		return 1
	fi

	# Helper to remove a file with sudo if needed
	remove_file_as_root() {
		local f="$1"
		if [[ $EUID -ne 0 ]]; then
			sudo rm -f "$f"
		else
			rm -f "$f"
		fi
	}

	# Decide whether to remove the lock
	local now epoch age
	if epoch=$(stat -c %Y "$lock_file" 2>/dev/null); then
		now=$(current_epoch)
		age=$((now - epoch))
	else
		age=999999
	fi

	# Auto-remove in non-interactive mode (--noconfirm) or if the lock is older than 10 minutes
	if has_noconfirm_flag "$@" || [[ $age -ge 600 ]]; then
		echo -e "${YELLOW}Stale pacman lock detected (age: ${age}s). Removing it automatically...${NC}" >&2
		remove_file_as_root "$lock_file" || return 1
		return 0
	fi

	# Interactive prompt (15s timeout)
	echo -e "${YELLOW}A pacman lock exists but no active pacman is running.${NC}" >&2
	echo -e "${CYAN}Lock path:${NC} $lock_file (age: ${age}s)" >&2
	read -r -t 15 -p $'Remove stale lock and continue? [y/N]: ' reply || reply="n"
	if [[ ${reply,,} == "y" || ${reply,,} == "yes" ]]; then
		remove_file_as_root "$lock_file" || return 1
		return 0
	fi
	echo -e "${RED}Aborting due to existing pacman lock. Close other updaters and retry, or run with --noconfirm to auto-clear stale locks.${NC}" >&2
	return 1
}
