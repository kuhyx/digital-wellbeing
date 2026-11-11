#!/bin/bash
# Deploys the music-parallelism user service from this repo: updates kuhy's
# ~/src checkout, copies the script tree to ~/.local/share/music-parallelism,
# installs the user unit pointing there, restarts it and health-checks it.
# Idempotent; exits non-zero unless the restarted unit is healthy. No sudo:
# the old /usr/local/bin/music-parallelism.sh is simply no longer referenced.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_DIR
readonly UNIT_NAME="music-parallelism.service"
readonly INSTALL_DIR="$HOME/.local/share/music-parallelism"
readonly UNIT_PATH="$HOME/.config/systemd/user/$UNIT_NAME"
# Empty string skips the pull (tests, or a machine without the checkout).
readonly SRC_CHECKOUT="${DEPLOY_SRC_CHECKOUT-$HOME/src/digital-wellbeing}"
readonly SETTLE_SEC="${DEPLOY_SETTLE_SEC:-3}"
readonly FILES=(music_parallelism.sh lib/music_detect.sh lib/music_monitor.sh
	lib/music_status.sh vendor/common.sh vendor/common_packages.sh
	vendor/common_services.sh vendor/common_datetime.sh)

die() {
	printf 'deploy: FAIL: %s\n' "$1" >&2
	exit 1
}

pull_checkout() {
	[[ -n $SRC_CHECKOUT && -d $SRC_CHECKOUT/.git ]] || return 0
	git -C "$SRC_CHECKOUT" pull --ff-only --quiet || die "pull of $SRC_CHECKOUT failed"
}

install_files() {
	local f
	for f in "${FILES[@]}"; do
		install -D -m "$([[ $f == *.sh && $f != */* ]] && echo 755 || echo 644)" \
			"$REPO_DIR/$f" "$INSTALL_DIR/$f"
	done
	mkdir -p "$(dirname "$UNIT_PATH")"
	sed "s|^ExecStart=.*|ExecStart=$INSTALL_DIR/music_parallelism.sh instant|" \
		"$REPO_DIR/systemd/$UNIT_NAME" >"$UNIT_PATH.tmp"
	mv "$UNIT_PATH.tmp" "$UNIT_PATH"
}

restart_unit() {
	systemctl --user daemon-reload
	systemctl --user enable --quiet "$UNIT_NAME"
	systemctl --user restart "$UNIT_NAME"
}

main_pid() {
	systemctl --user show -p MainPID --value "$UNIT_NAME"
}

health_check() {
	local f pid
	for f in "${FILES[@]}"; do
		cmp -s "$REPO_DIR/$f" "$INSTALL_DIR/$f" || die "$f differs from repo"
	done
	"$INSTALL_DIR/music_parallelism.sh" status >/dev/null || die "status failed"
	systemctl --user is-active --quiet "$UNIT_NAME" || die "$UNIT_NAME not active"
	pid=$(main_pid)
	[[ $pid =~ ^[1-9][0-9]*$ ]] || die "no MainPID"
	tr '\0' ' ' <"/proc/$pid/cmdline" | grep -qF "$INSTALL_DIR/music_parallelism.sh" ||
		die "MainPID $pid does not run $INSTALL_DIR"
	# Crash loop check: still active with the same PID after a pause.
	sleep "$SETTLE_SEC"
	systemctl --user is-active --quiet "$UNIT_NAME" || die "$UNIT_NAME died"
	[[ $(main_pid) == "$pid" ]] || die "$UNIT_NAME restarted during settle"
}

main() {
	pull_checkout
	install_files
	restart_unit
	health_check
	echo "deploy: OK $UNIT_NAME active, pid $(main_pid)"
}

main "$@"
