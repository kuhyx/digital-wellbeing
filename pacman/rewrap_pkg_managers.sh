#!/bin/bash
# rewrap_pkg_managers.sh — restore the pacman + makepkg wrapper symlinks.
#
# A `pacman-git` upgrade reinstalls /usr/bin/pacman and /usr/bin/makepkg as the
# stock binaries, clobbering our wrapper symlinks. This helper re-establishes
# them (refreshing the .orig backups from the freshly installed binaries) so the
# wrappers survive upgrades.
#
# It is invoked by the PostTransaction pacman hook (96-restore-pkg-wrappers.hook)
# and by the periodic drift verifier. It does FILE OPS ONLY — it never calls
# pacman — so it is safe to run inside a pacman transaction hook without deadlock.

set -euo pipefail

# rewrap <real_path> <orig_backup> <wrapper_dest>
rewrap() {
	local real="$1" orig="$2" wrapper="$3"
	# Nothing to point at — skip rather than create a dangling symlink.
	if [[ ! -e $wrapper ]]; then
		echo "rewrap: wrapper missing, skipping: $wrapper" >&2
		return 0
	fi
	if [[ ! -L $real ]]; then
		# Real binary present (fresh install, or an upgrade replaced our symlink):
		# refresh the .orig backup, then re-point the symlink at the wrapper.
		# When $real IS already our symlink we must NOT copy — that would put the
		# wrapper into .orig and cause an exec loop.
		[[ -e $real ]] && cp -f "$real" "$orig"
	fi
	ln -sf "$wrapper" "$real"
}

rewrap /usr/bin/pacman  /usr/bin/pacman.orig  /usr/local/bin/pacman_wrapper
rewrap /usr/bin/makepkg /usr/bin/makepkg.orig /usr/local/bin/makepkg_wrapper
