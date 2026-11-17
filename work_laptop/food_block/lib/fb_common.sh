#!/bin/bash
# Shared helpers for food-block. Sourced by apply.sh and install.sh; uses
# their ROOT (path prefix, empty = real /).

log() { printf 'food-block: %s\n' "$*"; }
warn() { printf 'food-block: WARN %s\n' "$*" >&2; }
die() {
	printf 'food-block: ERROR %s\n' "$*" >&2
	exit 1
}

# chattr only on the real root: scratch roots live on tmpfs, which has no
# immutable flag. A chattr failure (overlayfs, odd fs) warns, never aborts:
# the timer re-applying the file is the real guarantee, +i is a speed bump.
set_immutable() { # set_immutable +i|-i <file>
	[[ -z $ROOT ]] || return 0
	chattr "$1" "$2" 2>/dev/null || warn "chattr $1 failed on $2"
}

# write_if_changed <target> <rendered-file> <lock:0|1>
# Replaces <target> only when its content differs, so an unchanged tick does
# no writes (and does not re-trigger the /etc/hosts path unit). Writes in
# place with cat to keep the inode, owner and mode of existing files.
write_if_changed() {
	local target="$1" rendered="$2" lock="$3"
	if [[ -f $target ]] && cmp -s "$target" "$rendered"; then
		if [[ $lock == 1 ]]; then set_immutable +i "$target"; fi
		return 0
	fi
	mkdir -p "$(dirname "$target")"
	[[ -f $target ]] && set_immutable -i "$target"
	cat "$rendered" >"$target"
	chmod 644 "$target"
	if [[ $lock == 1 ]]; then set_immutable +i "$target"; fi
	log "restored $target"
}
