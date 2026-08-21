#!/usr/bin/env bash
# lib/tests/leechblock_harness.sh — shared fixture for the install_leechblock.sh split.
#
# Sourced, not executed. Scope is deliberately narrow: the phases that download
# archives, pkill browsers, patch system binaries under sudo and write
# /etc/*/policies.json are never executed here — running them would rewrite
# this machine's browsers. Those phases are covered by the textual
# wrap-verification recorded in the evidence instead.
#
# What IS executed: the pure logic that decides *what* to do — tag resolution
# across its three curl fallbacks, version normalisation, and browser-table
# construction. curl/jq are shimmed on PATH so no network call is made.
set -euo pipefail

PASS=0
FAIL=0

_t_pass() {
	PASS=$((PASS + 1))
	printf '  OK: %s\n' "$1"
}

_t_fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL: %s\n' "$1"
}

_t_eq() {
	local want="$1"
	local got="$2"
	local what="$3"
	if [[ $got == "$want" ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (want '${want}', got '${got}')"
	fi
}

_t_has() {
	local haystack="$1"
	local needle="$2"
	local what="$3"
	if [[ $haystack == *"$needle"* ]]; then
		_t_pass "$what"
	else
		_t_fail "$what (want a substring '${needle}')"
	fi
}

# A function that calls `exit` would kill the test script if invoked directly
# in an `if` condition, so failures are asserted inside a subshell.
_t_exits_nonzero() {
	local what="$2"
	if ("$1" >/dev/null 2>&1); then
		_t_fail "$what (expected a non-zero exit, got 0)"
	else
		_t_pass "$what"
	fi
}

LEECHBLOCK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export LEECHBLOCK_LIB_DIR

# The libs expect these logging helpers from the entry script.
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; }
err() { printf '[ERR ] %s\n' "$*"; }

# Build a throwaway PATH front so `curl`, `jq` and friends are controllable.
# Every shim writes what it was asked for into $TEST_TMPDIR so assertions can
# inspect the call, and reads its canned reply from a per-test file.
_t_setup_shims() {
	TEST_TMPDIR="$(mktemp -d)"
	SHIM_DIR="$TEST_TMPDIR/bin"
	mkdir -p "$SHIM_DIR"

	cat >"$SHIM_DIR/curl" <<'SHIM'
#!/usr/bin/env bash
# Records argv, then replays a canned body chosen by the caller.
printf '%s\n' "$*" >>"$TEST_TMPDIR/curl.calls"
if [[ -n ${CURL_FAIL_ALL:-} ]]; then
	exit 22
fi
if [[ $* == *"-fsSLI"* ]]; then
	[[ -f "$TEST_TMPDIR/curl.head" ]] && cat "$TEST_TMPDIR/curl.head"
	exit 0
fi
if [[ $* == *"/releases/latest"* ]]; then
	[[ -f "$TEST_TMPDIR/curl.releases" ]] && cat "$TEST_TMPDIR/curl.releases"
	exit 0
fi
if [[ $* == *"/tags"* ]]; then
	[[ -f "$TEST_TMPDIR/curl.tags" ]] && cat "$TEST_TMPDIR/curl.tags"
	exit 0
fi
exit 0
SHIM
	chmod +x "$SHIM_DIR/curl"

	# _t_hide_jq narrows PATH to SHIM_DIR alone, so every external command still
	# needed on that path must be reachable from here: awk/tr for the
	# redirect-header fallback, env+bash because the curl shim's own shebang is
	# `#!/usr/bin/env bash`, and rm/cat/mktemp for the harness itself.
	# Without these the fallback would fail for the wrong reason and the test
	# would be asserting nothing.
	# mkdir is load-bearing: detect_browsers creates the desktop-entry dir, and
	# a missing mkdir aborts the whole suite under `set -e` with no stderr at
	# all — which under kcov looks like a coverage-tool problem rather than a
	# PATH problem. Keep this list in sync with the externals the libs call.
	local tool
	for tool in awk tr cat mkdir mktemp rm env bash sed grep wc readlink; do
		ln -sf "$(command -v "$tool")" "$SHIM_DIR/$tool"
	done

	export TEST_TMPDIR
	PATH="$SHIM_DIR:$PATH"
	export PATH
}

# Narrow PATH to the shim dir alone. Two tests need this and neither can be
# written any other way:
#   * hiding jq — shadowing it with a non-executable shim is NOT enough,
#     because `command -v` keeps searching PATH and finds the real jq;
#   * hiding browsers — this machine genuinely has Chromium and Firefox
#     installed, so "no browser detected" is otherwise untestable.
# _t_setup_shims pre-seeds the shim dir with the utilities the code under test
# calls, so narrowing hides only what the test means to hide.
_t_isolate_path() {
	_T_SAVED_PATH="$PATH"
	PATH="$SHIM_DIR"
	export PATH
}

_t_restore_path() {
	PATH="$_T_SAVED_PATH"
	export PATH
}

# Readable aliases for the jq-specific use of the same mechanism.
_t_hide_jq() { _t_isolate_path; }
_t_show_jq() { _t_restore_path; }

_t_teardown() {
	[[ -n ${TEST_TMPDIR:-} && -d ${TEST_TMPDIR} ]] && rm -rf "$TEST_TMPDIR"
}

_t_report() {
	printf '\n%s: %d passed, %d failed\n' "${1:-tests}" "$PASS" "$FAIL"
	[[ $FAIL -eq 0 ]]
}
