#!/usr/bin/env bash

# Remove Guest Mode in Chromium-based browsers (especially thorium-browser) on Arch Linux
# - Applies enterprise policies at system level to hide/disable Guest mode and adding new people
# - Supports: thorium-browser, chromium, google-chrome(-stable), brave-browser, vivaldi, microsoft-edge-stable, opera
# - Provides --undo mode

set -euo pipefail

SCRIPT_NAME=$(basename "$0")

UNDO=false

for arg in "$@"; do
	case "$arg" in
	--undo) UNDO=true ;;
	-h | --help)
		cat <<EOF
Usage: $SCRIPT_NAME [--undo]

Actions:
	(default)  Write managed policy JSON to disable Guest mode
	--undo     Remove the policy files created by this script

Options:
	-h,--help  Show this help

Notes:
	- Requires root privileges to write to /etc/* policy paths. Will self-elevate via sudo.
	- Restart affected browsers to apply changes.
EOF
		exit 0
		;;
	esac
done

# Re-exec as root if needed
if [[ $EUID -ne 0 ]]; then
	echo "[info] Elevating privileges with sudo..."
	exec sudo -E bash "$0" "$@"
fi

# Map binaries to a logical product key
declare -A BIN_TO_KEY=(
	[thorium - browser]=thorium-browser
	[thorium]=thorium-browser
	[chromium]=chromium
	[google - chrome]=google-chrome
	[google - chrome - stable]=google-chrome
	[brave - browser]=brave-browser
	[vivaldi]=vivaldi
	[vivaldi - stable]=vivaldi
	[microsoft - edge - stable]=microsoft-edge-stable
	[opera]=opera
)

# Candidate policy directories per product key (first existing or first creatable is used)
declare -A CANDIDATE_DIRS=(
	[thorium - browser]="/etc/thorium/policies/managed:/etc/opt/thorium/policies/managed:/etc/opt/thorium-browser/policies/managed:/etc/thorium-browser/policies/managed"
	[chromium]="/etc/chromium/policies/managed"
	[google - chrome]="/etc/opt/chrome/policies/managed"
	[brave - browser]="/etc/opt/brave/policies/managed"
	[vivaldi]="/etc/opt/vivaldi/policies/managed"
	[microsoft - edge - stable]="/etc/opt/edge/policies/managed"
	[opera]="/etc/opt/opera/policies/managed"
)

POLICY_FILENAME="99-disable-guest-mode.json"

POLICY_JSON='{
	"BrowserGuestModeEnabled": false,
	"BrowserAddPersonEnabled": false
}'

# Discover installed browsers
declare -A INSTALLED_KEYS=()
for bin in "${!BIN_TO_KEY[@]}"; do
	if command -v "$bin" >/dev/null 2>&1; then
		key=${BIN_TO_KEY[$bin]}
		INSTALLED_KEYS[$key]=1
	fi
done

if [[ ${#INSTALLED_KEYS[@]} -eq 0 ]]; then
	echo "[warn] No supported Chromium-based browsers detected in PATH. Proceeding to configure Thorium paths anyway."
	INSTALLED_KEYS[thorium - browser]=1
fi

choose_target_dir() {
	local key="$1"
	local IFS=":"
	local dirs
	read -r -a dirs <<<"${CANDIDATE_DIRS[$key]:-}"
	# Prefer an existing directory; else pick the first candidate
	for d in "${dirs[@]}"; do
		if [[ -d $d ]]; then
			echo "$d"
			return 0
		fi
	done
	echo "${dirs[0]}"
}

apply_policy() {
	local target_dir="$1"
	shift
	local file="$target_dir/$POLICY_FILENAME"

	echo "[apply] $file"

	mkdir -p "$target_dir"
	# Write atomically
	local tmp
	tmp=$(mktemp)
	printf '%s
' "$POLICY_JSON" >"$tmp"
	install -m 0644 "$tmp" "$file"
	rm -f "$tmp"
}

remove_policy() {
	local target_dir="$1"
	shift
	local file="$target_dir/$POLICY_FILENAME"

	if [[ -f $file ]]; then
		echo "[remove] $file"
		rm -f -- "$file"
	else
		echo "[skip] $file (not present)"
	fi
}

changed_any=false

for key in "${!INSTALLED_KEYS[@]}"; do
	# If we somehow lack candidate dirs for a key, skip gracefully
	if [[ -z ${CANDIDATE_DIRS[$key]:-} ]]; then
		echo "[warn] No known policy directories for '$key'; skipping."
		continue
	fi

	target_dir=$(choose_target_dir "$key")

	if [[ $UNDO == true ]]; then
		remove_policy "$target_dir"
	else
		apply_policy "$target_dir"
	fi

	changed_any=true
done

if [[ $changed_any == false ]]; then
	echo "[info] Nothing to do."
fi

if [[ $UNDO == true ]]; then
	echo "[done] Guest mode policy files removed where present. You may need to restart the browsers."
else
	echo "[done] Guest mode disabled via managed policies. Please fully restart affected browsers."
	echo "       If the Guest option still appears, it should be disabled/greyed out."
fi
