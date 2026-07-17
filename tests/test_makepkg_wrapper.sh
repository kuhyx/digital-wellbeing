#!/bin/bash
# Tests for the makepkg wrapper + shared stale-lock library.
#
# Covers: script syntax, structural invariants (fail-open source guard,
# FAKEROOTKEY bypass, .orig-refresh, integrity), and the actual stale-lock
# behaviour exercised against a TEMP lock file (never the real system lock).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAC_DIR="$SCRIPT_DIR/../scripts/periodic_background/digital_wellbeing/pacman"
LIB="$PAC_DIR/pacman_lock_lib.sh"
WRAPPER="$PAC_DIR/makepkg_wrapper.sh"
INSTALLER="$PAC_DIR/install_makepkg_wrapper.sh"
REWRAP="$PAC_DIR/rewrap_pkg_managers.sh"
HOOK="$PAC_DIR/96-restore-pkg-wrappers.hook"

pass=0
fail=0
ok()  { echo "✓ $1"; pass=$((pass + 1)); }
bad() { echo "✗ $1"; fail=$((fail + 1)); }

echo "=== Testing makepkg wrapper + shared stale-lock library ==="

# --- Syntax ---------------------------------------------------------------
for f in "$LIB" "$WRAPPER" "$INSTALLER" "$REWRAP"; do
	if bash -n "$f"; then ok "syntax valid: $(basename "$f")"; else bad "syntax error: $(basename "$f")"; fi
done

# --- Structural invariants ------------------------------------------------
if grep -q 'PACMAN_LOCK_FILE:-/var/lib/pacman/db.lck' "$LIB"; then
	ok "lib lock path is overridable for tests (defaults to real path)"
else bad "lib does not parameterise PACMAN_LOCK_FILE"; fi

if grep -q 'pacman_process_running' "$LIB"; then
	ok "lib has cross-user pgrep guard (pacman_process_running)"
else bad "lib missing cross-user pgrep guard"; fi

if grep -q 'FAKEROOTKEY' "$WRAPPER"; then
	ok "wrapper has FAKEROOTKEY bypass fast-path"
else bad "wrapper missing FAKEROOTKEY bypass"; fi

# Fail-open: a missing lib must exec real makepkg rather than break it.
if awk '/-r "\$_LIB_DIR\/pacman_lock_lib.sh"/{g=1} g&&/exec "\$MAKEPKG_BIN"/{seen=1} END{exit !seen}' "$WRAPPER"; then
	ok "wrapper fails OPEN when lib missing (execs real makepkg)"
else bad "wrapper does not fail open on missing lib"; fi

if grep -q 'if \[ ! -L /usr/bin/makepkg \]' "$INSTALLER"; then
	ok "installer refreshes makepkg.orig only when not our symlink (no exec loop)"
else bad "installer .orig guard missing/incorrect"; fi

if grep -q 'When = PostTransaction' "$HOOK" && grep -q 'rewrap_pkg_managers.sh' "$HOOK"; then
	ok "survival hook is PostTransaction and runs rewrap helper"
else bad "survival hook malformed"; fi

# Invalid alpm Operation values abort EVERY pacman transaction (alpm parses all
# hooks up front), so the hook must use only Install/Upgrade/Remove.
if grep -E '^Operation' "$HOOK" | grep -qvE '^Operation = (Install|Upgrade|Remove)$'; then
	bad "hook has an invalid alpm Operation value (would break all pacman transactions)"
else ok "hook uses only valid alpm Operation values"; fi

# --- Functional (temp lock, no root) --------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"; jobs -p | xargs -r kill 2>/dev/null || true' EXIT
LOCK="$TMP/db.lck"
STUB="$TMP/makepkg.stub"
printf '#!/bin/bash\nprintf "%%s" "$*" > "%s/args"\n' "$TMP" > "$STUB"
chmod +x "$STUB"

# Source the lib once. check_and_handle_db_lock reads $PACMAN_LOCK_FILE at call
# time, so pointing it at the temp lock before sourcing is enough for all cases.
export PACMAN_LOCK_FILE="$LOCK"
# shellcheck source=../scripts/periodic_background/digital_wellbeing/pacman/pacman_lock_lib.sh
source "$LIB"

# orphaned + --noconfirm -> cleared
: > "$LOCK"
check_and_handle_db_lock --noconfirm >/dev/null 2>&1 || true
if [[ ! -e $LOCK ]]; then ok "orphaned lock + --noconfirm cleared"; else bad "orphaned lock not cleared"; fi

# absent -> no-op, returns 0
if check_and_handle_db_lock --noconfirm >/dev/null 2>&1; then ok "absent lock is a no-op"; else bad "absent lock returned non-zero"; fi

# old (>=600s) -> auto-removed without --noconfirm
: > "$LOCK"
touch -d '2 hours ago' "$LOCK"
check_and_handle_db_lock >/dev/null 2>&1 || true
if [[ ! -e $LOCK ]]; then ok "old orphaned lock auto-removed without --noconfirm"; else bad "age-based removal failed"; fi

# running 'pacman' process -> removal blocked (cross-user pgrep guard)
: > "$LOCK"
FAKE="$TMP/pacman"
cp /bin/sleep "$FAKE"
setsid "$FAKE" 20 &
fp=$!
sleep 0.3
if check_and_handle_db_lock --noconfirm >/dev/null 2>&1; then blocked=0; else blocked=1; fi
if [[ $blocked -eq 1 && -e $LOCK ]]; then ok "running 'pacman' process blocks removal"; else bad "pgrep guard failed"; fi
kill "$fp" 2>/dev/null || true
sleep 0.2
rm -f "$LOCK"

# wrapper: non-install invocation bypasses, leaves lock, execs real makepkg
: > "$LOCK"
MAKEPKG_BIN="$STUB" bash "$WRAPPER" --version >/dev/null 2>&1 || true
if [[ -e $LOCK && "$(cat "$TMP/args" 2>/dev/null)" == "--version" ]]; then ok "wrapper: non-install bypasses, lock untouched"; else bad "wrapper non-install bypass failed"; fi

# wrapper: -sif clears orphaned lock then execs real makepkg
: > "$LOCK"
MAKEPKG_BIN="$STUB" bash "$WRAPPER" -sif --noconfirm >/dev/null 2>&1 || true
if [[ ! -e $LOCK && "$(cat "$TMP/args" 2>/dev/null)" == "-sif --noconfirm" ]]; then ok "wrapper: -sif clears orphaned lock then execs makepkg"; else bad "wrapper install pre-flight failed"; fi

# wrapper: FAKEROOTKEY (build sandbox) bypasses, keeps lock
: > "$LOCK"
MAKEPKG_BIN="$STUB" FAKEROOTKEY=deadbeef bash "$WRAPPER" -sif --noconfirm >/dev/null 2>&1 || true
if [[ -e $LOCK ]]; then ok "wrapper: FAKEROOTKEY bypass keeps lock"; else bad "wrapper fakeroot bypass failed"; fi

echo ""
echo "=== Result: $pass passed, $fail failed ==="
if [[ $fail -eq 0 ]]; then echo "=== All Tests Passed! ==="; else exit 1; fi
