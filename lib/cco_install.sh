#!/bin/bash
# Install/uninstall of the per-app wrappers, the flat lib deployment and the
# pacman rewrap hook for block_compulsive_opening.sh.
# Sourced by the entry script; inherits its strict mode and globals.

# Install wrapper for a specific app
install_wrapper() {
	local app="$1"
	local wrapper_path="${APPS[$app]}"
	local real_binary="${REAL_BINARIES[$app]}"

	# Check if already wrapped: .orig must exist AND current file must be our wrapper
	if [[ -f "${wrapper_path}.orig" ]]; then
		if grep -q "block-compulsive-opening" "$wrapper_path" 2>/dev/null; then
			echo "  ✓ $app already wrapped"
			return 0
		else
			# .orig exists but wrapper was overwritten (e.g. by package update)
			echo "  ↻ $app wrapper was overwritten, re-installing..."
			rm -f "${wrapper_path}.orig"
			# Fall through to re-install
		fi
	fi

	# Check if wrapper location exists (file or symlink)
	if [[ ! -e $wrapper_path && ! -L $wrapper_path ]]; then
		echo "  ⚠ $app not installed ($wrapper_path not found)"
		return 1
	fi

	# Check if real binary exists.
	# Special case: when the exec target IS this wrapper's own backup
	# ("${wrapper_path}.orig") the app has no separate system binary — the
	# launcher itself is the real thing, and the wrap below CREATES the .orig by
	# moving it aside. Requiring it to exist beforehand is a chicken-and-egg that
	# could never pass. The wrapper_path check above already proved it installed.
	if [[ $real_binary != "${wrapper_path}.orig" && ! -x $real_binary ]]; then
		echo "  ⚠ $app real binary not found ($real_binary)"
		return 1
	fi

	echo "  Installing wrapper for $app..."

	# Handle symlinks: save the symlink itself, not the target
	if [[ -L $wrapper_path ]]; then
		local link_target
		link_target=$(readlink "$wrapper_path")
		echo "    Saving symlink $wrapper_path -> $link_target as ${wrapper_path}.orig"
		# Remove symlink and create .orig that stores the link target info
		echo "SYMLINK:$link_target" >"${wrapper_path}.orig"
		rm "$wrapper_path"
	else
		echo "    Backing up $wrapper_path -> ${wrapper_path}.orig"
		mv "$wrapper_path" "${wrapper_path}.orig"
	fi

	echo "    Creating wrapper at $wrapper_path"
	cat >"$wrapper_path" <<WRAPPER_EOF
#!/bin/bash
# Auto-generated wrapper for $app - blocks compulsive opening
# Real binary: $real_binary
# Original script: ${wrapper_path}.orig
exec /usr/local/bin/block-compulsive-opening.sh wrapper "$app" "\$@"
WRAPPER_EOF

	chmod +x "$wrapper_path"
	echo "  ✓ $app wrapper installed"
}

# Uninstall wrapper for a specific app
uninstall_wrapper() {
	local app="$1"
	local wrapper_path="${APPS[$app]}"

	if [[ ! -f "${wrapper_path}.orig" ]]; then
		echo "  ⚠ $app wrapper not found"
		return 1
	fi

	echo "  Removing wrapper for $app..."
	rm -f "$wrapper_path"

	# Check if it was a symlink (stored as SYMLINK:target in .orig)
	local orig_content
	orig_content=$(cat "${wrapper_path}.orig" 2>/dev/null || echo "")
	if [[ $orig_content == SYMLINK:* ]]; then
		local link_target="${orig_content#SYMLINK:}"
		echo "    Restoring symlink $wrapper_path -> $link_target"
		ln -s "$link_target" "$wrapper_path"
		rm "${wrapper_path}.orig"
	else
		echo "    Restoring original file"
		mv "${wrapper_path}.orig" "$wrapper_path"
	fi
	echo "  ✓ $app restored"
}

# Install all wrappers
install_all() {
	echo "Installing compulsive opening blockers..."
	echo ""

	# Install main script to /usr/local/bin
	local script_path
	script_path="$(readlink -f "$0")"
	local install_path="/usr/local/bin/block-compulsive-opening.sh"

	if [[ $script_path != "$install_path" ]]; then
		echo "Installing main script to $install_path..."
		cp "$script_path" "$install_path"
		chmod +x "$install_path"
		echo "✓ Main script installed"
	else
		echo "Main script already at $install_path"
	fi

	# The libs travel with the entry script, FLAT beside it rather than in a
	# lib/ subdirectory — the same shape as /usr/local/bin/pacman_lock_lib.sh
	# and heavy_job_lock.sh. The entry script probes for lib/ first and falls
	# back to its own directory, so both layouts work.
	#
	# This must run even when the script is already at $install_path: a lib
	# added or changed upstream still has to reach /usr/local/bin, and
	# `rewrap-quiet` from the pacman hook runs the DEPLOYED copy, which would
	# otherwise keep sourcing stale libs.
	local lib_src="$_CCO_LIB_DIR"
	local lib_dest="/usr/local/bin"
	if [[ $lib_src != "$lib_dest" ]]; then
		echo "Installing libraries to $lib_dest..."
		local lib
		for lib in cco_state cco_wrapper cco_install cco_report; do
			cp "$lib_src/${lib}.sh" "$lib_dest/${lib}.sh"
			chmod +x "$lib_dest/${lib}.sh"
		done
		echo "✓ Libraries installed"
	fi
	echo ""

	# Install wrappers for each app
	local installed=0
	for app in "${!APPS[@]}"; do
		if install_wrapper "$app"; then
			((installed++)) || true
		fi
	done

	echo ""
	echo "Installation complete. $installed app(s) wrapped."
	echo ""
	echo "Each app can now only be opened once per hour."
	echo "State files stored in: $STATE_DIR"
	echo "Logs stored in: $LOG_FILE"

	# Install pacman hook to re-wrap after package updates
	install_pacman_hook
}

# Install pacman hook to re-install wrappers after package updates
install_pacman_hook() {
	local hook_dir="/etc/pacman.d/hooks"
	local hook_file="$hook_dir/95-compulsive-block-rewrap.hook"

	echo ""
	echo "Installing pacman hook..."

	mkdir -p "$hook_dir"

	cat >"$hook_file" <<'HOOK_EOF'
[Trigger]
Operation = Upgrade
Operation = Install
Type = Package
Target = beeper
Target = signal-desktop
Target = discord

[Action]
Description = Re-installing compulsive opening blockers after package update
When = PostTransaction
Exec = /usr/local/bin/block-compulsive-opening.sh rewrap-quiet
HOOK_EOF

	chmod 644 "$hook_file"
	echo "✓ Pacman hook installed: $hook_file"
	echo "  Wrappers will be automatically re-installed after beeper/signal/discord updates"
}

# Uninstall pacman hook
uninstall_pacman_hook() {
	local hook_file="/etc/pacman.d/hooks/95-compulsive-block-rewrap.hook"
	if [[ -f $hook_file ]]; then
		rm -f "$hook_file"
		echo "✓ Pacman hook removed"
	fi
}

# Quietly re-wrap apps (for pacman hook - no interactive output)
rewrap_quiet() {
	log_message "REWRAP: Pacman hook triggered, re-installing wrappers"

	for app in "${!APPS[@]}"; do
		local wrapper_path="${APPS[$app]}"

		# Re-wrap if wrapper is missing or was overwritten by a package update
		if [[ ! -f "${wrapper_path}.orig" ]] || ! grep -q "block-compulsive-opening" "$wrapper_path" 2>/dev/null; then
			log_message "REWRAP: $app wrapper missing or overwritten, re-installing"
			rm -f "${wrapper_path}.orig"
			install_wrapper "$app" >>"$LOG_FILE" 2>&1 || true
		fi
	done

	log_message "REWRAP: Complete"
}

# Uninstall all wrappers
uninstall_all() {
	echo "Removing compulsive opening blockers..."
	echo ""

	for app in "${!APPS[@]}"; do
		uninstall_wrapper "$app" || true
	done

	rm -f "/usr/local/bin/block-compulsive-opening.sh"

	# The libs install_all copied flat beside the entry script go with it;
	# leaving them behind would strand four orphans in /usr/local/bin.
	local lib
	for lib in cco_state cco_wrapper cco_install cco_report; do
		rm -f "/usr/local/bin/${lib}.sh"
	done

	# Remove pacman hook
	uninstall_pacman_hook

	echo ""
	echo "Uninstallation complete."
}
