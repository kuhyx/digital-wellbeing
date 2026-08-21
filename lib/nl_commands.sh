#!/usr/bin/env bash
# Helpers sourced by the entry script.

cmd_setup() {
	set_actual_user_vars
	print_setup_header "Night Lockdown"

	ensure_dir "$STATE_DIR"
	[[ -f "$STATE_FILE" ]] || echo UNLOCKED >"$STATE_FILE"

	write_config
	install_enter_script
	install_unlock_script
	install_unlock_units
	install_rgb_off_service
	install_i2c_modules

	systemctl daemon-reload
	enable_service night-lockdown-unlock.timer
	enable_service rgb-off.service

	echo ""
	if verify_install; then
		log_ok "Night lockdown installed."
	else
		log_warn "Night lockdown installed with warnings (see above)."
	fi
	echo ""
	log_info "Next: swap the shutdown action by re-running setup_midnight_shutdown.sh"
	log_info "      (it must call $ENTER_SCRIPT instead of powering off)."
	log_info "Emergency unlock over SSH:  sudo $0 unlock"
}

cmd_status() {
	local state="unknown"
	[[ -r "$STATE_FILE" ]] && state="$(cat "$STATE_FILE")"
	echo "Night lockdown state : $state"
	echo "lightdm.service      : $(systemctl is-active lightdm.service 2>/dev/null || true)"
	echo "getty@.service mask  : $(systemctl is-enabled getty@.service 2>/dev/null || true)"
	echo "autovt@.service mask : $(systemctl is-enabled autovt@.service 2>/dev/null || true)"
	echo "unlock timer         : $(systemctl is-active night-lockdown-unlock.timer 2>/dev/null || true) / $(systemctl is-enabled night-lockdown-unlock.timer 2>/dev/null || true)"
	echo ""
	echo "Next unlock triggers:"
	systemctl list-timers night-lockdown-unlock.timer --no-pager 2>/dev/null || true
}

cmd_unlock() {
	log_info "Emergency unlock: restoring GUI now"
	DRY_RUN="" "$UNLOCK_SCRIPT"
	echo ""
	log_warn "The curfew is still armed: the next 30-min check tick will re-lock."
	log_warn "To stay unlocked until morning, register an override (friction by design):"
	if [[ -x "$OVERRIDE_MANAGER" ]]; then
		local now_h until_str
		now_h="$(date '+%Y-%m-%d %H:%M')"
		# Next 05:00 boundary (tomorrow if already past 05:00 today).
		if [[ "$(date +%H)" -lt 5 ]]; then
			until_str="$(date '+%Y-%m-%d') 05:00"
		else
			until_str="$(date -d tomorrow '+%Y-%m-%d') 05:00"
		fi
		echo "    sudo $OVERRIDE_MANAGER add '$now_h' '$until_str' 'emergency unlock'"
	else
		log_warn "  (override manager not found at $OVERRIDE_MANAGER)"
	fi
}

usage() {
	cat <<EOF
Night Lockdown — replace the midnight power-off with a GUI lockout that keeps
background servers running.

Usage:
  sudo $0 setup      Install/refresh the lock+unlock action and morning timer
       $0 status     Show current lockdown state and timer status
  sudo $0 unlock     Emergency: lift the lockdown right now (use over SSH)
       $0 help       Show this help

After 'setup', re-run setup_midnight_shutdown.sh so the scheduled check calls
$ENTER_SCRIPT instead of powering off.
EOF
}
