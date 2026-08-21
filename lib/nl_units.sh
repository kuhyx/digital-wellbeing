#!/usr/bin/env bash
# Helpers sourced by the entry script.

install_unlock_units() {
	log_info "Installing morning-unlock timer family"
	cat >"$UNLOCK_SERVICE" <<EOF
$MANAGED_BANNER
[Unit]
Description=Lift night lockdown (restore GUI, unmute, unmask login surface)
DefaultDependencies=false
After=multi-user.target

[Service]
Type=oneshot
ExecStart=$UNLOCK_SCRIPT
StandardOutput=journal
StandardError=journal
EOF

	# Multiple staggered triggers + Persistent=true = dead-man robustness: a
	# single missed/failed 05:00 run cannot strand the machine, and each run is
	# idempotent so repeated firing is harmless.
	cat >"$UNLOCK_TIMER" <<EOF
$MANAGED_BANNER
[Unit]
Description=Morning triggers to lift night lockdown

[Timer]
OnCalendar=*-*-* 05:00:00
OnCalendar=*-*-* 05:15:00
OnCalendar=*-*-* 05:30:00
OnCalendar=*-*-* 06:00:00
OnCalendar=*-*-* 07:00:00
Persistent=true
AccuracySec=1s

[Install]
WantedBy=timers.target
EOF
}

# Lights stay off at ALL times, not just during lockdown. The board firmware
# re-lights RAM/board/GPU on every power-on, so without this the RGB would be
# back after each reboot and only go dark again at the next 21:00 lock.
install_rgb_off_service() {
	log_info "Installing boot-time RGB-off service"
	cat >"$RGB_OFF_SERVICE" <<EOF
$MANAGED_BANNER
[Unit]
Description=Turn all RGB lighting off (lights are meant to be off at all times)
After=multi-user.target
# The i2c DRAM/GPU controllers need their buses; the ASRock controller is USB.
Wants=systemd-modules-load.service
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
# HOME pinned for the same reason as in the lock/unlock scripts: openrgb keeps
# its state under HOME and systemd would otherwise differ from an interactive
# sudo run. Detection takes ~2s before it applies. static+black rather than
# "off": the ZOTAC GPU has no Off mode and the ASRock board ignores it.
ExecStart=/usr/bin/env HOME=${RGB_HOME_DEFAULT} /usr/bin/openrgb --mode static --color 000000
SuccessExitStatus=0 1
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
}

verify_install() {
	log_info "Verifying installation"
	local ok=true
	local path
	for path in "$ENTER_SCRIPT" "$UNLOCK_SCRIPT" "$CONF_FILE" \
		"$UNLOCK_SERVICE" "$UNLOCK_TIMER" "$RGB_OFF_SERVICE" "$I2C_MODULES_FILE"; do
		if [[ -e "$path" ]]; then
			log_ok "present: $path"
		else
			log_error "missing: $path"
			ok=false
		fi
	done
	if is_service_enabled night-lockdown-unlock.timer; then
		log_ok "night-lockdown-unlock.timer is enabled"
	else
		log_error "night-lockdown-unlock.timer is NOT enabled"
		ok=false
	fi
	# The action swap in the fortress check script is what actually invokes us.
	if grep -q "$ENTER_SCRIPT" /usr/local/bin/day-specific-shutdown-check.sh 2>/dev/null; then
		log_ok "day-specific-shutdown-check.sh calls the lockdown action"
	else
		log_warn "day-specific-shutdown-check.sh does NOT call $ENTER_SCRIPT yet"
		log_warn "  → re-run setup_midnight_shutdown.sh to regenerate it (see header)"
	fi
	[[ "$ok" == true ]]
}
