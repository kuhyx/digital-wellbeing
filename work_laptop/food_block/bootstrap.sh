#!/bin/bash
# One-line installer for the work laptop. Pinned to a commit so the laptop
# never runs whatever main happens to be:
#
#   curl -fsSL https://raw.githubusercontent.com/kuhyx/digital-wellbeing/<rev>/work_laptop/food_block/bootstrap.sh | sudo bash -s <rev>
#
# Downloads that commit's tarball, runs install.sh from it, deletes the copy.

set -euo pipefail

readonly REV="${1:-}"
readonly REPO=kuhyx/digital-wellbeing

[[ $REV =~ ^[0-9a-f]{7,40}$ ]] || {
	echo "usage: bootstrap.sh <commit-hash>" >&2
	exit 1
}
[[ $EUID -eq 0 ]] || {
	echo "run as root (pipe into sudo bash -s <rev>)" >&2
	exit 1
}
command -v curl >/dev/null || {
	apt-get update -qq
	apt-get install -y -qq curl >/dev/null
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REV" | tar -xz -C "$work" --strip-components=1
bash "$work/work_laptop/food_block/install.sh"
