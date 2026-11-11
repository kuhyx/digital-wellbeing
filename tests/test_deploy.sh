#!/bin/bash
# Tests scripts/deploy.sh against a temp HOME and a stubbed systemctl: files
# land where the unit expects them, a rerun is a no-op, and a unit that does
# not come up makes the deploy exit non-zero.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
DEPLOY="$REPO_DIR/scripts/deploy.sh"

fail() {
	printf 'FAIL: %s\n' "$1" >&2
	exit 1
}

TMP_DIR=$(mktemp -d)
FAKE_PID=""
cleanup() {
	[[ -n $FAKE_PID ]] && kill "$FAKE_PID" 2>/dev/null || true
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT

[[ -x $DEPLOY ]] || fail "scripts/deploy.sh missing or not executable"

export HOME="$TMP_DIR/home"
mkdir -p "$HOME" "$TMP_DIR/bin"
INSTALL_DIR="$HOME/.local/share/music-parallelism"
UNIT="$HOME/.config/systemd/user/music-parallelism.service"

# A process whose cmdline names the deployed script stands in for the unit.
bash -c "exec -a '$INSTALL_DIR/music_parallelism.sh' sleep 300" &
FAKE_PID=$!

# systemctl stub: logs calls; reports the state in $TMP_DIR/state.
cat >"$TMP_DIR/bin/systemctl" <<STUB
#!/bin/bash
echo "\$*" >>"$TMP_DIR/calls"
case "\$*" in
*is-active*) cat "$TMP_DIR/state"; [[ \$(cat "$TMP_DIR/state") == active ]] ;;
*MainPID*) echo "$FAKE_PID" ;;
*) exit 0 ;;
esac
STUB
chmod +x "$TMP_DIR/bin/systemctl"
export PATH="$TMP_DIR/bin:$PATH"
export DEPLOY_SRC_CHECKOUT="" DEPLOY_SETTLE_SEC=0

echo active >"$TMP_DIR/state"
"$DEPLOY" >"$TMP_DIR/out1" 2>&1 || fail "deploy exited non-zero: $(cat "$TMP_DIR/out1")"
for f in music_parallelism.sh lib/music_detect.sh lib/music_monitor.sh \
	lib/music_status.sh vendor/common.sh vendor/common_services.sh; do
	cmp -s "$REPO_DIR/$f" "$INSTALL_DIR/$f" || fail "$f not deployed"
done
[[ -x $INSTALL_DIR/music_parallelism.sh ]] || fail "deployed script not executable"
grep -qx "ExecStart=$INSTALL_DIR/music_parallelism.sh instant" "$UNIT" ||
	fail "unit ExecStart not rewritten"
grep -q 'restart music-parallelism.service' "$TMP_DIR/calls" || fail "no restart"

before=$(find "$HOME" -type f | sort | xargs md5sum)
"$DEPLOY" >"$TMP_DIR/out2" 2>&1 || fail "second deploy exited non-zero"
after=$(find "$HOME" -type f | sort | xargs md5sum)
[[ $before == "$after" ]] || fail "second deploy changed files"

echo failed >"$TMP_DIR/state"
if "$DEPLOY" >"$TMP_DIR/out3" 2>&1; then
	fail "deploy exited 0 although the unit is not active"
fi

echo "PASS: deploy installs, is idempotent, fails on a dead unit"
