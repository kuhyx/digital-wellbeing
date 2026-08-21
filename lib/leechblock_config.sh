#!/usr/bin/env bash
# Default-configuration seeding for install_leechblock.sh.
# Sourced by the installer; inherits its strict mode and info/warn helpers.
# Reads SCRIPT_DIR, writes the browser LevelDB storage via the Node seeder.

inject_default_config() {
	# ── Inject default blocking configuration ─────────────────────────────
	# Write default blocking rules directly into Chrome's LevelDB extension
	# storage via Node.js (classic-level).  This is content-verification-proof:
	# we never touch any extension JS file, so Chrome cannot detect tampering.
	DEFAULTS_SRC="$SCRIPT_DIR/leechblock_defaults.json"

	if [[ -f $DEFAULTS_SRC ]]; then

		# Ensure classic-level is available next to this script.
		if [[ ! -d "$SCRIPT_DIR/node_modules/classic-level" ]]; then
			info "Installing classic-level npm package into $SCRIPT_DIR ..."
			npm install --prefix "$SCRIPT_DIR" 2>&1 | grep -v '^npm warn' || true
		fi

		# Chrome locks its LevelDB files while running — close all Chromium browsers
		# so the write succeeds.
		pkill -f 'google-chrome|chromium|brave-browser|vivaldi|thorium' 2>/dev/null || true
		sleep 1

		# Seed defaults into every Chrome/Chromium profile found on this machine.
		if node "$SCRIPT_DIR/seed_leechblock_storage.js" "$DEFAULTS_SRC"; then
			info "Seeded default LeechBlock settings into browser storage"
		else
			warn "Could not seed LeechBlock defaults — run manually after install:"
			warn "  node $SCRIPT_DIR/seed_leechblock_storage.js $DEFAULTS_SRC"
		fi
	else
		warn "leechblock_defaults.json not found at $DEFAULTS_SRC — skipping default config"
	fi
}
