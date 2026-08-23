#!/bin/bash
# vendor/common.sh sources three sibling libs unconditionally. Vendoring only
# common.sh left those three missing: the four functions the entry points need
# still loaded, so every suite passed, while each invocation printed three
# "No such file or directory" errors to stderr.
#
# Nothing else catches this. The suites exercise the unit's own lib/, not the
# vendored copy, and a `source` failure of a sibling is non-fatal here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
VENDOR="$REPO_DIR/vendor"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

# 1. Sourcing must be SILENT. Anything on stderr means a missing dependency.
stderr="$(bash -c "SCRIPT_DIR='$REPO_DIR'; source '$VENDOR/common.sh'" 2>&1 >/dev/null)"
[[ -z $stderr ]] || fail "sourcing vendor/common.sh wrote to stderr: $stderr"
echo "  OK: vendor/common.sh sources without errors"

# 2. Every file it sources must be present beside it.
while IFS= read -r dep; do
	[[ -f "$VENDOR/$dep" ]] || fail "vendor/common.sh sources $dep, which is not vendored"
	echo "  OK: $dep is vendored"
done < <(grep -oE "source \"[$]_COMMON_DIR/[a-z_]+\.sh\"" "$VENDOR/common.sh" |
	sed 's#.*/##; s#"##')

# 3. The functions the entry points actually call must be defined.
for fn in log log_message require_root set_actual_user_vars; do
	found="$(bash -c "SCRIPT_DIR='$REPO_DIR'; source '$VENDOR/common.sh' 2>/dev/null; type -t $fn" || true)"
	[[ $found == "function" ]] || fail "$fn is not defined after sourcing vendor/common.sh"
done
echo "  OK: log, log_message, require_root and set_actual_user_vars are all defined"

# 4. Each entry point must name a vendored path that exists.
for entry in music_parallelism.sh youtube-music-wrapper.sh \
	setup_midnight_shutdown.sh setup_night_lockdown.sh; do
	grep -q 'SCRIPT_DIR/vendor/common.sh' "$REPO_DIR/$entry" ||
		fail "$entry does not source vendor/common.sh"
done
echo "  OK: all four entry points source vendor/common.sh"

echo "vendor closure checks passed."
