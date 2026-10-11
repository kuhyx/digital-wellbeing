#!/usr/bin/env bash
# Covers the package-REMOVAL path: pkg_owns_path, prune_stale_wrapper, the
# prune step in rewrap_quiet, and the Remove trigger in the generated hook.
#
# Removing e.g. the discord package deletes our wrapper (it sits on the
# package's /usr/bin/discord) but leaves /usr/bin/discord.orig, the real
# launcher, which then bypasses the blocker. Everything here runs against the
# harness's tmpdir APPS paths and a fixture pacman db, never /usr/bin or /etc.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=cco_harness.sh
. "$HERE/cco_harness.sh"
# shellcheck source=../cco_state.sh
. "$CCO_LIB_DIR/cco_state.sh"
# shellcheck source=../cco_install.sh
. "$CCO_LIB_DIR/cco_install.sh"

_t_cco_setup
trap _t_cco_teardown EXIT

DB="$TEST_TMPDIR/db"
export CCO_PACMAN_LOCAL_DB="$DB"

# Fake installed package <name> owning <abs-path>, in pacman's files format.
_own() { # <pkg> <abs-path>
	mkdir -p "$DB/$1-1-1"
	printf '%%FILES%%\n%s\n' "${2#/}" >"$DB/$1-1-1/files"
}

_wrapper_marker() { # <path> -- what install_wrapper would leave on the path
	printf '#!/bin/bash\nexec /usr/local/bin/block-compulsive-opening.sh wrapper x\n' >"$1"
}

_exists() { [[ -e $1 || -L $1 ]]; }

_t_gone() { # <path> <what>
	if _exists "$1"; then _t_fail "$2"; else _t_pass "$2"; fi
}

_t_kept() { # <path> <what>
	if _exists "$1"; then _t_pass "$2"; else _t_fail "$2"; fi
}

_t_status() { # <want-rc> <what> <cmd...>
	local want="$1" what="$2" rc=0
	shift 2
	"$@" >/dev/null 2>&1 || rc=$?
	_t_eq "$want" "$rc" "$what"
}

discord="${APPS[discord]}"
signal="${APPS[signal-desktop]}"

printf 'pkg_owns_path: answers from the local db\n'
_t_status 2 "no db at all is undeterminable" pkg_owns_path "$discord"
_own signal-desktop "$signal"
_t_status 0 "a listed path is owned" pkg_owns_path "$signal"
_t_status 1 "an unlisted path is unowned" pkg_owns_path "$discord"
_t_status 1 "a prefix of a listed path is not a match" pkg_owns_path "${signal%-desktop}"

printf '\nprune_stale_wrapper: a removed package leaves only .orig\n'
echo launcher >"$discord.orig"
_t_status 0 "a stale .orig is pruned" prune_stale_wrapper discord
_t_gone "$discord.orig" "the stale .orig is deleted"
_t_has "$(cat "$LOG_FILE")" "PRUNE: discord package removed" "the prune is logged"
_t_status 1 "a second run finds nothing (idempotent)" prune_stale_wrapper discord

printf '\nprune_stale_wrapper: a dangling wrapper goes with the .orig\n'
echo launcher >"$discord.orig"
_wrapper_marker "$discord"
_t_status 0 "stale .orig + our wrapper is pruned" prune_stale_wrapper discord
_t_gone "$discord" "the dangling wrapper is deleted"

printf '\nprune_stale_wrapper: a foreign file on the path is not ours to delete\n'
echo launcher >"$discord.orig"
echo 'someone else' >"$discord"
_t_status 0 "the stale .orig is still pruned" prune_stale_wrapper discord
_t_eq "someone else" "$(cat "$discord")" "a file without our marker is kept"
rm -f "$discord"

printf '\nprune_stale_wrapper: a SYMLINK-style .orig is pruned too\n'
ln -s /nonexistent "$discord.orig"
_t_status 0 "a dangling .orig symlink counts" prune_stale_wrapper discord
_t_gone "$discord.orig" "the .orig symlink is deleted"

printf '\nprune_stale_wrapper: an installed package keeps its wrap\n'
echo launcher >"$signal.orig"
_wrapper_marker "$signal"
_t_status 1 "an owned path is not stale" prune_stale_wrapper signal-desktop
_t_kept "$signal.orig" "the owned .orig is kept"
_t_status 1 "no .orig means nothing to prune" prune_stale_wrapper beeper

printf '\nprune_stale_wrapper: an undeterminable db never deletes\n'
echo launcher >"$discord.orig"
CCO_PACMAN_LOCAL_DB="$TEST_TMPDIR/no-such-db" _t_status 1 "a missing db prunes nothing" prune_stale_wrapper discord
_t_kept "$discord.orig" "the .orig survives a missing db"

printf '\nrewrap_quiet: prunes the removed app, still re-wraps an upgraded one\n'
# discord: removed (stale .orig above). signal-desktop: upgraded, so the
# package's fresh launcher overwrote our wrapper.
printf '#!/bin/bash\necho real\n' >"${REAL_BINARIES[signal-desktop]}"
chmod +x "${REAL_BINARIES[signal-desktop]}"
echo 'fresh launcher' >"$signal"
rewrap_quiet 2>/dev/null
_t_gone "$discord.orig" "the removed app's .orig is gone"
_t_gone "$discord" "no wrapper is created for the removed app"
_t_has "$(cat "$signal")" "block-compulsive-opening" "the upgraded app is re-wrapped"
_t_eq "fresh launcher" "$(cat "$signal.orig")" "its fresh launcher becomes the .orig"
before="$(cat "$signal" "$signal.orig")"
rewrap_quiet 2>/dev/null
_t_eq "$before" "$(cat "$signal" "$signal.orig")" "a second rewrap changes nothing (idempotent)"

printf '\nrewrap_quiet: a missing state dir does not skip the re-wrap\n'
# The pacman hook runs as root, whose STATE_DIR usually does not exist yet; the
# log redirect on install_wrapper then failed and the app was left UNWRAPPED.
rm -rf "$STATE_DIR"
echo 'fresh launcher 2' >"$signal"
rewrap_quiet 2>/dev/null
_t_has "$(cat "$signal")" "block-compulsive-opening" "the upgraded app is re-wrapped without a state dir"

printf '\ninstall_wrapper: install prunes instead of reporting "already wrapped"\n'
echo launcher >"$discord.orig"
_wrapper_marker "$discord"
out="$(install_wrapper discord 2>/dev/null || true)"
_t_has "$out" "package removed" "install names the prune"
_t_gone "$discord.orig" "install deletes the stale .orig"

printf '\ninstall_pacman_hook: the hook also fires on removal\n'
export CCO_HOOK_DIR="$TEST_TMPDIR/hooks"
install_pacman_hook >/dev/null
hook="$(cat "$CCO_HOOK_DIR/95-compulsive-block-rewrap.hook")"
_t_has "$hook" "Operation = Remove" "Remove is a trigger"
_t_has "$hook" "Operation = Upgrade" "Upgrade is still a trigger"
_t_has "$hook" "Target = discord" "discord is still a target"

_t_report "test_cco_prune"
