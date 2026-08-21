#!/bin/bash
# Block Compulsive Opening Script
# Limits messaging apps (Beeper, Signal, Discord) to one launch per hour
#
# Each app can only be opened once per hour. If already opened this hour,
# subsequent launch attempts are blocked with a notification.
#
# Installation moves real binaries to *.real and symlinks to wrapper scripts.

set -euo pipefail

# The phases live in four libs. They are found in TWO layouts, because this
# script runs from both:
#
#   repo:     <here>/lib/cco_*.sh
#   deployed: /usr/local/bin/cco_*.sh   (flat, beside the entry script)
#
# install_all copies the libs flat next to the installed entry script rather
# than creating /usr/local/bin/lib, matching how pacman_lock_lib.sh and
# heavy_job_lock.sh are already deployed there.
#
# readlink -f because /usr/bin/<app> wrappers exec this through its absolute
# path and the installed copy may itself be reached via a symlink.
#
# This fails CLOSED: a missing lib aborts. The pacman fail-open pattern is
# wrong here — a half-loaded blocker that silently stops blocking is the exact
# failure this tool exists to prevent, and unlike pacman you do not need this
# script to repair it.
_CCO_DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
if [[ -d "$_CCO_DIR/lib" ]]; then
	_CCO_LIB_DIR="$_CCO_DIR/lib"
else
	_CCO_LIB_DIR="$_CCO_DIR"
fi

for _cco_lib in cco_state cco_wrapper cco_install cco_report; do
	if [[ ! -r "$_CCO_LIB_DIR/${_cco_lib}.sh" ]]; then
		echo "Error: missing library ${_cco_lib}.sh in $_CCO_LIB_DIR" >&2
		echo "The installation is incomplete; re-run: sudo $0 install" >&2
		exit 1
	fi
done
unset _cco_lib

# shellcheck source=lib/cco_state.sh
. "$_CCO_LIB_DIR/cco_state.sh"
# shellcheck source=lib/cco_wrapper.sh
. "$_CCO_LIB_DIR/cco_wrapper.sh"
# shellcheck source=lib/cco_install.sh
. "$_CCO_LIB_DIR/cco_install.sh"
# shellcheck source=lib/cco_report.sh
. "$_CCO_LIB_DIR/cco_report.sh"

# Send desktop notification (inlined from common.sh to avoid dependency issues
# when script is installed to /usr/local/bin)
notify() {
	local title="$1"
	local message="$2"
	local urgency="${3:-normal}"
	local timeout="${4:-5000}"

	if command -v notify-send &>/dev/null; then
		notify-send -u "$urgency" -t "$timeout" "$title" "$message" 2>/dev/null || true
	fi
}

# Configuration
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/compulsive-block"
LOG_FILE="$STATE_DIR/compulsive-block.log"

# Auto-close timeout in minutes (apps forcefully closed after this)
AUTO_CLOSE_TIMEOUT_MINUTES=10
# Warning before auto-close (in minutes before timeout)
AUTO_CLOSE_WARNING_MINUTES=2

# Per-app timeout overrides (apps not listed use AUTO_CLOSE_TIMEOUT_MINUTES)
declare -A APP_TIMEOUT_MINUTES=(
	["beeper"]=20
	["signal-desktop"]=20
)

# Apps to limit (name -> binary path)
# These are the primary wrapper locations (what the user calls)
declare -A APPS=(
	["beeper"]="/usr/bin/beeper"
	["signal-desktop"]="/usr/bin/signal-desktop"
	["discord"]="/usr/bin/discord"
)

# The wrapper runs as the user ($SUDO_USER unset); the installer runs as root
# under sudo ($SUDO_USER set) — resolve the same home in both cases.
_cco_user="${SUDO_USER:-${USER:-$(id -un)}}"
_cco_home="$(getent passwd "$_cco_user" 2>/dev/null | cut -d: -f6)"
[[ -n $_cco_home ]] || _cco_home="/home/$_cco_user"

# Actual executable paths (the real binaries to exec after wrapper check)
# These are where the real code lives
#
# discord: the `discord` package ships ONLY /usr/bin/discord — a bootstrap shell
# script that downloads the app into ~/.config/discord/ and execs
# ~/.config/discord/Discord (a symlink to the current app-<version>/Discord that
# Discord's own updater maintains). /opt/discord/Discord belongs to a DIFFERENT
# discord package and does not exist here, so the old value made install_wrapper's
# `[[ -x $real_binary ]]` gate fail forever ("discord real binary not found") and
# discord was never limited. We exec the preserved LAUNCHER (.orig) rather than
# the app directly, so Discord's bootstrap/self-update still runs — pointing
# straight at ~/.config/discord/Discord would break launching whenever the
# updater moved that symlink.
declare -A REAL_BINARIES=(
	["beeper"]="/opt/beeper/beepertexts"
	["signal-desktop"]="/usr/lib/signal-desktop/signal-desktop"
	["discord"]="/usr/bin/discord.orig"
)

# Pattern for detecting a RUNNING instance (pgrep -f). Defaults to the exec
# target, which is right when that target is the app itself. It is wrong when the
# exec target is a launcher that exec()s away: /usr/bin/discord.orig replaces
# itself with ~/.config/discord/<app>/Discord, so nothing would ever match
# ".orig" and the running-state tracking would look stale immediately.
declare -A PROCESS_MATCH=(
	["discord"]="$_cco_home/.config/discord/"
)

# Main entry point
main() {
	case "${1:-help}" in
	install)
		if [[ $EUID -ne 0 ]]; then
			echo "Error: install requires root privileges"
			echo "Run: sudo $0 install"
			exit 1
		fi
		install_all
		;;
	uninstall)
		if [[ $EUID -ne 0 ]]; then
			echo "Error: uninstall requires root privileges"
			echo "Run: sudo $0 uninstall"
			exit 1
		fi
		uninstall_all
		;;
	status)
		show_status
		;;
	reset)
		if [[ -z ${2:-} ]]; then
			echo "Error: specify app to reset"
			echo "Apps: ${!APPS[*]}"
			exit 1
		fi
		reset_app "$2"
		;;
	reset-all)
		reset_all
		;;
	rewrap-quiet)
		# Called by pacman hook - quietly re-wrap apps after package updates
		if [[ $EUID -ne 0 ]]; then
			exit 1
		fi
		rewrap_quiet
		;;
	wrapper)
		if [[ -z ${2:-} ]]; then
			echo "Error: wrapper requires app name"
			exit 1
		fi
		wrapper_main "${@:2}"
		;;
	help | -h | --help)
		show_usage
		;;
	*)
		echo "Unknown command: $1"
		show_usage
		exit 1
		;;
	esac
}

main "$@"
