#!/bin/sh
# worker.sh - mrdark state machine, supervised by procd.
# Commands arrive via /tmp/mrdark/cmd, state goes to /tmp/mrdark/status.json.

. /usr/libexec/mrdark/lib.sh
. /usr/libexec/mrdark/radio.sh
. /usr/libexec/mrdark/status.sh

on_term() {
	mrd_log info "worker: TERM received"
	/usr/libexec/mrdark/cleanup.sh
	exit 0
}
trap on_term TERM INT

# ---------------------------------------------------------------- helpers

reset_round() {
	for _s in $(mrd_queue_sections); do
		[ "$(mrd_tget "$_s" status pending)" = "closed" ] && continue
		mrd_tset "$_s" status pending
		mrd_tset "$_s" reason ""
	done
}

targets_pending() {
	for _s in $(mrd_queue_sections); do
		[ "$(mrd_tget "$_s" status pending)" = "pending" ] && printf '%s\n' "$_s"
	done
}

targets_open() {
	for _s in $(mrd_queue_sections); do
		[ "$(mrd_tget "$_s" status pending)" = "closed" ] || printf '%s\n' "$_s"
	done
}

set_active() {
	_s=$1
	mrd_sput job.active "$_s"
	mrd_sput job.bssid "$(uci -q get "mrdark.$_s.bssid" 2>/dev/null)"
	mrd_sput job.essid "$(uci -q get "mrdark.$_s.essid" 2>/dev/null)"
	mrd_sput job.channel "$(uci -q get "mrdark.$_s.channel" 2>/dev/null)"
	mrd_tset "$_s" status active
}

close_target() {
	mrd_tset "$1" status closed
	mrd_tset "$1" reason "$2"
	mrd_log info "target $1 closed: $2"
}

# --------------------------------------------------------------- commands

job_start() {
	if [ -z "$(mrd_queue_sections)" ]; then
		mrd_error E_NO_TARGETS "queue is empty"
		return 1
	fi
	if [ "$(mrd_cfg confirm_authorized 0)" != "1" ]; then
		mrd_error E_NOT_AUTHORIZED "authorisation is not confirmed"
		return 1
	fi

	# a manual start is a new session: forget counters and per-target status of
	# the whole queue first (artefact files on disk are kept). This must happen
	# before the radio checks, otherwise a wedged radio would keep the old
	# "closed" state forever.
	for _s in $(mrd_queue_sections); do
		rm -f "$MRD_STATE/t.$_s".* 2>/dev/null
	done
	mrd_sput job.bssid ""
	mrd_sput job.essid ""
	mrd_sput job.channel ""
	mrd_sput job.last_pair ""
	mrd_sput job.last_sta ""

	mrd_radio_prepare
	_rc=$?
	if [ "$_rc" -eq 1 ]; then
		mrd_error E_NO_MONITOR "no monitor-capable 2.4GHz phy found"
		return 1
	elif [ "$_rc" -eq 2 ]; then
		return 1
	fi

	_phy=$(mrd_sget sys.phy)
	if ! mrd_mon_ensure; then
		mrd_error E_MONITOR_FAIL "cannot create $MRD_MON on $_phy"
		return 1
	fi

	# make sure the radio really receives before touching a target
	if ! mrd_mon_health; then
		mrd_log warn "job start: no frames on $MRD_MON, recovering radio"
		mrd_sput sys.need_reload 1
		if ! mrd_mon_ensure || ! mrd_mon_health; then
			mrd_error E_RADIO "radio receives nothing"
			return 1
		fi
	fi

	_dir=$(mrd_cfg artifacts_dir /root/cap)
	# only a hard safety floor; the artefacts cap itself is storage_max_mb and
	# is enforced when archiving
	_free=$(mrd_free_mb "$_dir")
	if [ -n "$_free" ] && [ "$_free" -lt 1 ]; then
		mrd_error E_NO_SPACE "artefact storage is full (${_free}MB free)"
		return 1
	fi

	mrd_clear_error

	reset_round
	mrd_sput sys.state running
	mrd_sput sys.started "$(mrd_now)"
	mrd_sput job.phase prepare
	mrd_sput job.next_run 0
	mrd_sput job.round 1
	mrd_sput job.active ""
	mrd_sput job.attempt 0
	mrd_syslog "mrdark: job started (phy $_phy)"
	mrd_log info "job started on phy $_phy"
	return 0
}

handle_failure() {
	_s=$1
	_f=$(mrd_tget "$_s" fails 0)
	_f=$((_f + 1))
	mrd_tset "$_s" fails "$_f"

	# 0 = unlimited: the job must keep trying until caps_target is reached
	_maxf=$(mrd_tcfg "$_s" max_fails_in_row 0)
	_maxt=$(mrd_tcfg "$_s" max_attempts_total 0)
	case "$_maxf" in ''|*[!0-9]*) _maxf=0 ;; esac
	case "$_maxt" in ''|*[!0-9]*) _maxt=0 ;; esac
	_att=$(mrd_tget "$_s" attempts 0)

	if [ "$_maxf" -gt 0 ] && [ "$_f" -ge "$_maxf" ]; then
		mrd_tset "$_s" fails 0
		mrd_tset "$_s" status skipped
		mrd_tset "$_s" reason "no_handshake"
		mrd_log info "target $_s skipped after $_f failures"
		switch_target
		return
	fi
	if [ "$_maxt" -gt 0 ] && [ "$_att" -ge "$_maxt" ]; then
		close_target "$_s" "max_attempts"
		switch_target
		return
	fi

	_ri=$(mrd_tcfg "$_s" retry_interval 180)
	mrd_sput job.phase waiting
	mrd_sput job.next_run "$(($(mrd_now) + _ri))"
	_logf="$_maxf"
	[ "$_maxf" -le 0 ] && _logf="inf"
	_logt="$_maxt"
	[ "$_maxt" -le 0 ] && _logt="inf"
	mrd_log info "retry $_s in ${_ri}s (fail ${_f}/${_logf}, attempts ${_att}/${_logt})"
}

do_attempt() {
	_s=$(mrd_sget job.active)
	if [ -z "$_s" ]; then
		switch_target
		return
	fi

	_att=$(mrd_tget "$_s" attempts 0)
	_att=$((_att + 1))
	mrd_tset "$_s" attempts "$_att"
	mrd_sput job.attempt "$_att"
	mrd_sput job.phase attempt
	mrd_status_write

	/bin/sh /usr/libexec/mrdark/attempt.sh "$_s" \
		"$(mrd_sget job.bssid)" "$(mrd_sget job.channel)"
	_rc=$?

	# a command arrived while we were busy
	case "$(mrd_cmd_peek)" in
		stop*) return ;;
	esac

	if [ "$_rc" -eq 0 ]; then
		_out=$(/bin/sh /usr/libexec/mrdark/archive.sh "$_s" \
			"$(mrd_sget job.bssid)" "$(mrd_sget job.essid)" \
			"$MRD_RAW/clean.cap" 2>>"$MRD_LOG")
		_arc=$?
		if [ "$_arc" -eq 0 ]; then
			_caps=$(mrd_tget "$_s" caps 0)
			_caps=$((_caps + 1))
			mrd_tset "$_s" caps "$_caps"
			mrd_tset "$_s" fails 0
			mrd_sput job.last_artifact "$(printf '%s\n' "$_out" | head -n1)"
			mrd_syslog "mrdark: capture ok on $(mrd_sget job.bssid) ($(mrd_sget job.last_pair))"
			_max=$(mrd_tcfg "$_s" caps_target 100)
			if [ "$_caps" -ge "$_max" ]; then
				close_target "$_s" "caps_target"
				switch_target
				rm -f "$MRD_RAW/clean.cap"
				mrd_status_write
				return
			fi
			_si=$(mrd_tcfg "$_s" success_interval 300)
			mrd_sput job.phase waiting
			mrd_sput job.next_run "$(($(mrd_now) + _si))"
			mrd_log info "next attempt for $_s in ${_si}s (after success, caps ${_caps}/${_max})"
		else
			handle_failure "$_s"
		fi
	else
		handle_failure "$_s"
	fi

	rm -f "$MRD_RAW/clean.cap" 2>/dev/null
	mrd_status_write
}

switch_target() {
	_next=
	for _x in $(targets_pending); do
		_next=$_x
		break
	done
	if [ -z "$_next" ]; then
		end_round
		return
	fi
	set_active "$_next"
	mrd_sput job.phase waiting
	mrd_sput job.next_run 0
	mrd_log info "target $_next -> $(mrd_sget job.bssid) ($(mrd_sget job.essid)) ch$(mrd_sget job.channel)"
	mrd_status_write
}

end_round() {
	if [ -z "$(targets_open)" ]; then
		mrd_sput job.phase finished
		mrd_sput sys.state idle
		mrd_sput job.active ""
		mrd_sput job.bssid ""
		mrd_sput job.essid ""
		mrd_sput job.channel ""
		mrd_sput job.attempt 0
		mrd_log info "all targets closed"
		mrd_syslog "mrdark: all targets closed"
		mrd_status_write
		case "$(mrd_cfg on_finish idle)" in
			halt)
				/usr/libexec/mrdark/cleanup.sh
				mrd_syslog "mrdark: halt requested by on_finish"
				halt
				;;
			reboot)
				/usr/libexec/mrdark/cleanup.sh
				reboot
				;;
		esac
		return
	fi

	_round=$(mrd_sgetd job.round 1)
	_round=$((_round + 1))
	mrd_sput job.round "$_round"
	_cp=$(mrd_cfg cyclic_pause 0)
	case "$_cp" in
		''|*[!0-9]*) _cp=0 ;;
	esac
	mrd_sput job.phase waiting
	mrd_sput job.active ""
	if [ "$_cp" -le 0 ]; then
		mrd_sput job.next_run 0
		mrd_log info "round $_round started immediately (cyclic_pause=0)"
	else
		mrd_sput job.next_run "$(($(mrd_now) + _cp))"
		mrd_log info "round $_round scheduled in ${_cp}s"
	fi
}

handle_cmd() {
	case "$1" in
		scan)
			/bin/sh /usr/libexec/mrdark/scan.sh
			;;
		start)
			job_start
			;;
		pause)
			[ "$(mrd_sget sys.state)" = "running" ] && mrd_sput sys.state paused
			;;
		resume)
			[ "$(mrd_sget sys.state)" = "paused" ] && mrd_sput sys.state running
			;;
		stop)
			/usr/libexec/mrdark/cleanup.sh
			mrd_sput sys.state idle
			mrd_syslog "mrdark: job stopped"
			;;
		skip)
			_a=$(mrd_sget job.active)
			if [ -n "$_a" ]; then
				mrd_tset "$_a" status skipped
				mrd_tset "$_a" reason "manual_skip"
				mrd_sput job.next_run 0
				switch_target
			fi
			;;
		reload)
			mrd_log info "reload: queue is $(mrd_queue_sections | wc -l) target(s)"
			;;
		recover)
			# explicit recovery request: bypass the reset throttle
			mrd_sput sys.state idle
			rm -f "$MRD_STATE/sys.last_recover" 2>/dev/null
			mrd_sput sys.need_reload 1
			if mrd_mon_ensure && mrd_mon_health; then
				mrd_clear_error
				mrd_log info "radio recovered: ch$(mrd_mon_channel), receiving"
			else
				mrd_error E_RADIO "radio still receives nothing (usb wedged?)"
			fi
			;;
		*)
			mrd_log warn "unknown command: $1"
			;;
	esac
	mrd_status_write
}

tick_running() {
	_phase=$(mrd_sgetd job.phase idle)
	_now=$(mrd_now)
	_next=$(mrd_sgetd job.next_run 0)

	case "$_phase" in
		prepare)
			switch_target
			;;
		waiting)
			if [ "$_now" -lt "$_next" ]; then
				return
			fi
			if [ -z "$(mrd_sget job.active)" ]; then
				reset_round
				switch_target
			else
				do_attempt
			fi
			;;
		finished)
			return
			;;
		*)
			do_attempt
			;;
	esac
}

# ------------------------------------------------------------------- main

mrd_init_dirs
if ! mrd_lock_acquire; then
	mrd_log warn "another worker instance is running, exiting"
	exit 0
fi

mrd_sput sys.state idle
mrd_sput job.phase idle
mrd_status_write

if [ "$(mrd_cfg autostart 0)" = "1" ] && [ -n "$(mrd_queue_sections)" ]; then
	mrd_log info "autostart enabled, starting job"
	job_start
fi

_i=0
while :; do
	_i=$((_i + 1))

	_cmd=$(mrd_cmd_take)
	if [ -n "$_cmd" ]; then
		handle_cmd "$_cmd"
		_i=0
	fi

	case "$(mrd_sget sys.state)" in
		running) tick_running ;;
	esac

	_st=$(mrd_sget sys.state)
	if [ "$_st" != "idle" ] || [ $((_i % 5)) -eq 0 ]; then
		mrd_status_write
	fi

	sleep 1
done
