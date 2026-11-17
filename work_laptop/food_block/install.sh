#!/bin/bash
# Installs the food-delivery block on the (Ubuntu) work laptop. Run as root
# from an extracted checkout; bootstrap.sh does that from a pinned commit.
#
# Installs root-owned copies to /usr/local/lib/food-block (apply.sh never
# runs from a checkout or /tmp), the systemd service/timer/path units, then
# applies once and checks that ubereats.com really resolves to 0.0.0.0.
# There is deliberately no uninstall script.
#
# Re-running it is safe and is the update path (it lifts +i, copies, relocks).

set -euo pipefail

readonly ROOT=""
SRC="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
readonly SRC
readonly DEST=/usr/local/lib/food-block
readonly UNIT_DIR=/etc/systemd/system
readonly UNITS=(food-block.service food-block.timer food-block.path)

# shellcheck source=lib/fb_common.sh
source "$SRC/lib/fb_common.sh"

[[ $EUID -eq 0 ]] || die "run as root: sudo bash $0"

ensure_tools() {
	local missing=()
	command -v jq >/dev/null || missing+=(jq)
	command -v chattr >/dev/null || missing+=(e2fsprogs)
	command -v getent >/dev/null || missing+=(libc-bin)
	((${#missing[@]} == 0)) && return 0
	log "installing ${missing[*]}"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq
	apt-get install -y -qq "${missing[@]}" >/dev/null
}

installed_files() {
	find "$DEST" -type f 2>/dev/null || true
	local unit
	for unit in "${UNITS[@]}"; do
		[[ -f $UNIT_DIR/$unit ]] && printf '%s\n' "$UNIT_DIR/$unit"
	done
	return 0
}

copy_files() {
	local f unit
	while IFS= read -r f; do set_immutable -i "$f"; done < <(installed_files)
	install -d -m 755 "$DEST" "$DEST/lib"
	install -m 755 "$SRC/apply.sh" "$DEST/apply.sh"
	install -m 644 "$SRC/domains.txt" "$DEST/domains.txt"
	install -m 644 "$SRC"/lib/*.sh "$DEST/lib/"
	for unit in "${UNITS[@]}"; do
		install -m 644 "$SRC/systemd/$unit" "$UNIT_DIR/$unit"
	done
	while IFS= read -r f; do set_immutable +i "$f"; done < <(installed_files)
}

enable_units() {
	if [[ ! -d /run/systemd/system ]]; then
		warn "systemd is not running: units installed but not started"
		return 0
	fi
	systemctl daemon-reload
	systemctl enable --now food-block.timer food-block.path >/dev/null
	systemctl is-active --quiet food-block.timer || die "food-block.timer is not active"
	systemctl is-active --quiet food-block.path || die "food-block.path is not active"
}

verify() {
	local answer
	answer="$(getent ahosts ubereats.com | awk '{print $1}' | sort -u | tr '\n' ' ')"
	case "$answer" in
	"0.0.0.0 " | ":: " | ":: 0.0.0.0 " | "0.0.0.0 :: ") ;;
	*) die "ubereats.com still resolves to: $answer" ;;
	esac
	log "verified: ubereats.com -> $answer"
	log "now restart every browser, then open chrome://policy / about:policies"
}

ensure_tools
copy_files
"$DEST/apply.sh"
enable_units
verify
