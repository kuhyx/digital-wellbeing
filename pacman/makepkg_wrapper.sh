#!/bin/bash
# makepkg_wrapper.sh — thin wrapper around /usr/bin/makepkg.
#
# WHY THIS EXISTS
# ---------------
# Vendored makepkg (shipped by the `pacman` package) has its own DB-lock wait in
# run_pacman(): `while [[ -f $lockfile ]]; do ... done`. It checks ONLY whether
# /var/lib/pacman/db.lck exists — never whether a live pacman actually owns it —
# and the outer loop has no timeout. So an ORPHANED lock (left by a pacman that
# was killed mid-transaction) makes `makepkg -i` hang forever, printing
# "Pacman is currently in use, please wait..." every ~30s.
#
# makepkg blocks in that loop BEFORE it ever invokes pacman, so the system's
# pacman_wrapper (which clears stale locks correctly) never gets a turn. This
# wrapper closes the gap: for install-bound invocations it clears an *orphaned*
# lock up front, then execs the real makepkg. A legitimate lock (held by a live
# pacman) is left untouched so makepkg waits as designed.
#
# makepkg is vendored and overwritten on `pacman-git` upgrades, so it must not be
# edited directly — wrapping it (mirroring the pacman_wrapper pattern) is the
# upgrade-safe fix.

set -euo pipefail

# Real makepkg, preserved by install_makepkg_wrapper.sh. Overridable via env so
# the shell test harness can point it at a stub (mirrors $PACMAN_LOCK_FILE);
# unset in production, so the default holds.
MAKEPKG_BIN="${MAKEPKG_BIN:-/usr/bin/makepkg.orig}"

# Source shared stale-lock helpers (co-located next to this wrapper). Fail SAFE:
# if the lib is missing/unreadable, do NOT break makepkg — exec the real binary
# and skip the pre-flight. A broken helper must never take down all builds.
_LIB_DIR="$(dirname "$(readlink -f "$0")")"
if [[ -r "$_LIB_DIR/pacman_lock_lib.sh" ]]; then
	# shellcheck source=pacman_lock_lib.sh
	source "$_LIB_DIR/pacman_lock_lib.sh"
else
	exec "$MAKEPKG_BIN" "$@"
fi

# Does this invocation ask makepkg to install (-i / --install)? Only install
# invocations reach makepkg's pacman lock-wait, so only then do we pre-clear.
# Handles bundled short flags (-i, -si, -sif, -if, ...). Stops at `--`.
invocation_installs() {
	local arg
	for arg in "$@"; do
		[[ $arg == "--" ]] && return 1
		[[ $arg == "--install" ]] && return 0
		# Single-dash short-flag cluster containing 'i' (makepkg's -i = install).
		[[ $arg == -[!-]* && $arg == *i* ]] && return 0
	done
	return 1
}

# Bypass fast-path: inside a fakeroot build sandbox (makepkg re-execs itself for
# the package() stage — FAKEROOTKEY is set), or for any invocation that won't
# install (won't hit the lock-wait). Mirrors the pacman_wrapper FAKEROOTKEY
# guard. Exec real makepkg unchanged.
if [[ -n ${FAKEROOTKEY:-} ]] || ! invocation_installs "$@"; then
	exec "$MAKEPKG_BIN" "$@"
fi

# Best-effort pre-flight clear. `check_and_handle_db_lock` removes the lock only
# when no live pacman owns it; if a real pacman holds it, it returns non-zero and
# we deliberately DO NOT abort — makepkg's own wait will (correctly) wait it out.
# Hence `|| true`: a live-holder verdict is not a makepkg failure here.
check_and_handle_db_lock "$@" || true

exec "$MAKEPKG_BIN" "$@"
