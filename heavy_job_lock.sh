#!/bin/bash

# ============================================================================
# heavy_job_lock.sh - one heavy job at a time on this machine
#
# This box has 7.6 GB. On 2026-08-03 a Gradle/Flutter APK build, a full
# `pytest --cov` run and Chromium overlapped; an earlier overlap the same week
# got a whole session OOM-killed (exit 137/143). The rule "one heavy job at a
# time" was written down in ~/.claude/memories/mistakes.md - but a rule that
# only works when a human remembers it is deployment hygiene, not a fix. This
# makes the overlap impossible instead.
#
# Usage as a CLI:
#     heavy_job_lock.sh --name gradle -- flutter build apk --debug
#     heavy_job_lock.sh --name pytest --fail-fast -- pytest --cov
#
# Usage as a library:
#     source /path/to/heavy_job_lock.sh
#     with_heavy_lock gradle -- ./gradlew assembleDebug
#
# Setup (once, as root - /run is tmpfs so the lock needs recreating on boot):
#     sudo heavy_job_lock.sh --install
#
# Design notes:
#   - ONE system-wide lock shared between root and the user. pacman runs as
#     root while builds run as the user, so a per-user /run/user/$UID lock
#     would give them separate locks and no mutual exclusion at all.
#   - The lock file is mode 0666 (created by root via tmpfiles.d) precisely so
#     an unprivileged build can take the same lock a root pacman takes.
#   - FAIL OPEN, always. A lock this central must never be able to brick
#     package management or builds: if the lock file cannot be created, or the
#     wait times out, we warn and run the command anyway. Blocking work forever
#     is a worse failure than the memory contention we are avoiding.
# ============================================================================

HEAVY_JOB_LOCK_FILE="${HEAVY_JOB_LOCK_FILE:-/run/heavy-job.lock}"
# Long enough for a real Gradle build to finish ahead of us, short enough that
# a wedged holder cannot stall a machine indefinitely.
HEAVY_JOB_LOCK_TIMEOUT="${HEAVY_JOB_LOCK_TIMEOUT:-1800}"
HEAVY_JOB_TMPFILES_CONF="/etc/tmpfiles.d/heavy-job-lock.conf"

_hjl_warn() { printf '[heavy-job-lock] %s\n' "$*" >&2; }

# Who holds it right now? Best-effort: the holder writes "<name> <pid> <date>"
# after acquiring, so a refusal can name the culprit instead of just failing.
_hjl_holder() {
	local holder=""
	[[ -r $HEAVY_JOB_LOCK_FILE ]] && read -r holder <"$HEAVY_JOB_LOCK_FILE" 2>/dev/null
	printf '%s' "${holder:-unknown}"
}

# Create the lock file world-writable. Only meaningful as root; unprivileged
# callers just discover they cannot and fail open.
_hjl_ensure_lock_file() {
	[[ -e $HEAVY_JOB_LOCK_FILE ]] && return 0
	if [[ $EUID -eq 0 ]]; then
		install -m 0666 /dev/null "$HEAVY_JOB_LOCK_FILE" 2>/dev/null && return 0
	else
		# Braces around the redirect: a failing redirection is reported by the
		# shell itself, before the command runs, so `cmd 2>/dev/null` does not
		# suppress it. The group does.
		{ : >"$HEAVY_JOB_LOCK_FILE"; } 2>/dev/null &&
			chmod 0666 "$HEAVY_JOB_LOCK_FILE" 2>/dev/null && return 0
	fi
	return 1
}

# with_heavy_lock <name> [--fail-fast] -- <command...>
with_heavy_lock() {
	local name="$1"
	shift
	local fail_fast=0

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--fail-fast)
			fail_fast=1
			shift
			;;
		--)
			shift
			break
			;;
		*) break ;;
		esac
	done

	if [[ $# -eq 0 ]]; then
		_hjl_warn "with_heavy_lock: no command given"
		return 2
	fi

	if ! _hjl_ensure_lock_file; then
		_hjl_warn "cannot create $HEAVY_JOB_LOCK_FILE - running '$name' UNSERIALISED"
		_hjl_warn "run 'sudo $0 --install' once to enable serialisation"
		"$@"
		return $?
	fi

	local lock_fd
	# `<>` (read-write), NOT `>`. Redirecting with `>` truncates the file at
	# open time, so a second caller wiped the holder's "<name> <pid> <date>"
	# line before it could read it — every refusal said "held by unknown".
	exec {lock_fd}<>"$HEAVY_JOB_LOCK_FILE" || {
		_hjl_warn "cannot open lock - running '$name' unserialised"
		"$@"
		return $?
	}

	local acquired=0
	if ((fail_fast == 1)); then
		if flock --nonblock "$lock_fd"; then
			acquired=1
		else
			_hjl_warn "refusing to start '$name': held by $(_hjl_holder)"
			exec {lock_fd}>&-
			return 75 # EX_TEMPFAIL
		fi
	else
		local holder
		holder="$(_hjl_holder)"
		if ! flock --nonblock "$lock_fd"; then
			_hjl_warn "waiting for '$holder' to finish before starting '$name' (timeout ${HEAVY_JOB_LOCK_TIMEOUT}s)"
		fi
		if flock --timeout "$HEAVY_JOB_LOCK_TIMEOUT" "$lock_fd"; then
			acquired=1
		else
			# Fail open: see the header. A stuck holder must not permanently
			# block builds or package management.
			_hjl_warn "timed out after ${HEAVY_JOB_LOCK_TIMEOUT}s waiting for $(_hjl_holder)"
			_hjl_warn "proceeding UNSERIALISED with '$name'"
		fi
	fi

	if ((acquired == 1)); then
		printf '%s %s %s\n' "$name" "$$" "$(date -Is 2>/dev/null || echo unknown)" \
			>"$HEAVY_JOB_LOCK_FILE" 2>/dev/null || true
	fi

	local rc=0
	"$@" || rc=$?

	# Closing the fd releases the lock; do it explicitly so the holder line is
	# not left implying we still hold it.
	exec {lock_fd}>&-
	return "$rc"
}

# ----------------------------------------------------------------------------
# CLI (skipped when this file is sourced as a library)
# ----------------------------------------------------------------------------
_hjl_install() {
	if [[ $EUID -ne 0 ]]; then
		_hjl_warn "--install must run as root"
		return 1
	fi
	# /run is tmpfs: without a tmpfiles.d entry the lock vanishes every boot and
	# the first unprivileged caller silently falls back to unserialised.
	printf 'f %s 0666 root root -\n' "$HEAVY_JOB_LOCK_FILE" >"$HEAVY_JOB_TMPFILES_CONF"
	systemd-tmpfiles --create "$HEAVY_JOB_TMPFILES_CONF" 2>/dev/null || true
	_hjl_ensure_lock_file || {
		_hjl_warn "failed to create $HEAVY_JOB_LOCK_FILE"
		return 1
	}
	printf 'installed %s and %s\n' "$HEAVY_JOB_TMPFILES_CONF" "$HEAVY_JOB_LOCK_FILE"
}

_hjl_usage() {
	cat <<EOF
Usage: $(basename "$0") --name <label> [--fail-fast] -- <command...>
       $(basename "$0") --install     # once, as root
       $(basename "$0") --status

Serialises heavy jobs (builds, coverage runs, pacman transactions) so only one
runs at a time on this memory-constrained machine. Always fails open.

Options:
  --name <label>   Name recorded as the lock holder (shown to whoever waits)
  --fail-fast      Refuse immediately if held, instead of waiting
  --install        Create the lock file + tmpfiles.d entry (root)
  --status         Show the current holder
EOF
}

# ${BASH_SOURCE[0]} != $0 means we were sourced - define functions, run nothing.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
	set -uo pipefail

	_name="heavy-job"
	_fail_fast=()
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--name)
			_name="$2"
			shift 2
			;;
		--fail-fast)
			_fail_fast=(--fail-fast)
			shift
			;;
		--install)
			_hjl_install
			exit $?
			;;
		--status)
			printf 'lock file: %s\n' "$HEAVY_JOB_LOCK_FILE"
			printf 'holder:    %s\n' "$(_hjl_holder)"
			exit 0
			;;
		-h | --help)
			_hjl_usage
			exit 0
			;;
		--)
			shift
			break
			;;
		*)
			_hjl_warn "unknown option: $1"
			exit 2
			;;
		esac
	done

	if [[ $# -eq 0 ]]; then
		_hjl_usage
		exit 2
	fi

	with_heavy_lock "$_name" "${_fail_fast[@]}" -- "$@"
	exit $?
fi
