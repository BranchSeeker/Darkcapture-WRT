#!/bin/sh
# scan.sh - one 2.4GHz scan pass.
# Captures with tcpdump while hopping channels, then lets mrdark-verify parse
# beacons/probe-responses/data frames into /tmp/mrdark/scan/networks.json.
#
# airodump-ng is intentionally NOT used: it does not capture on rtl8xxxu here
# (0 packets observed) and its CSV has no quoting for commas in ESSID.
#
# exit: 0 ok, 1 error

. /usr/libexec/mrdark/lib.sh
. /usr/libexec/mrdark/radio.sh
. /usr/libexec/mrdark/status.sh

MRD_CHANNELS="1 2 3 4 5 6 7 8 9 10 11 12 13"

mrd_scan_fail() {
	mrd_sput sys.scan_state error
	mrd_sput sys.scan_error "$1"
	mrd_sput sys.state idle
	mrd_error "$2" "$1"
	mrd_status_write
	return 1
}

mrd_scan_run() {
	mrd_init_dirs
	mrd_sput sys.state scanning
	mrd_sput sys.scan_state running
	mrd_sput sys.scan_progress 0
	mrd_sput sys.scan_count 0
	mrd_sput sys.scan_started "$(mrd_now)"
	rm -f "$MRD_STATE/sys.scan_error" 2>/dev/null
	mrd_clear_error
	mrd_status_write

	if ! mrd_mon_ensure; then
		mrd_scan_fail "cannot create $MRD_MON" E_MONITOR_FAIL
		return 1
	fi

	_scratch=$(mrd_cfg scratch_dir /tmp/mrdark)
	_free=$(mrd_free_mb "$_scratch")
	if [ -n "$_free" ] && [ "$_free" -lt 16 ]; then
		mrd_scan_fail "scratch has ${_free}MB free, need 16MB" E_NO_SPACE
		return 1
	fi

	# rtl8xxxu silently stops receiving after the monitor interface has been
	# re-created; a driver reload brings it back (see radio.sh header)
	if ! mrd_mon_health; then
		mrd_log warn "scan: no frames on $MRD_MON, reloading driver"
		mrd_sput sys.need_reload 1
		if ! mrd_mon_ensure || ! mrd_mon_health; then
			mrd_scan_fail "radio receives nothing" E_RADIO
			return 1
		fi
	fi

	_dur=$(mrd_cfg scan_duration 30)
	case "$_dur" in
		''|*[!0-9]*) _dur=30 ;;
	esac
	[ "$_dur" -ge 10 ] || _dur=10

	_nch=0
	for _c in $MRD_CHANNELS; do
		_nch=$((_nch + 1))
	done
	_per=$((_dur / _nch))
	[ "$_per" -ge 1 ] || _per=1
	# hard deadline: a wedged driver must not hang the worker forever
	_deadline=$(($(mrd_now) + _dur + 40))

	rm -f "$MRD_SCAN"/scan*.pcap 2>/dev/null
	_cap="$MRD_SCAN/scan.pcap"

	tcpdump -i "$MRD_MON" -U -s 512 -w "$_cap" >/dev/null 2>"$MRD_SCAN/tcpdump.err" &
	_pid=$!
	mrd_pid_write tcpdump "$_pid"
	sleep 1
	if ! kill -0 "$_pid" 2>/dev/null; then
		mrd_scan_fail "tcpdump failed to start" E_TCPDUMP
		return 1
	fi

	_i=0
	_done=0
	_abort=0
	_late=0
	for _c in $MRD_CHANNELS; do
		case "$(mrd_cmd_peek)" in
			stop*) _abort=1; break ;;
		esac
		mrd_set_channel "$_c" || mrd_log warn "scan: cannot set channel $_c"
		_j=0
		while [ "$_j" -lt "$_per" ]; do
			case "$(mrd_cmd_peek)" in
				stop*) _abort=1; break ;;
			esac
			if [ "$(mrd_now)" -gt "$_deadline" ]; then
				_late=1
				break
			fi
			sleep 1
			_j=$((_j + 1))
			_i=$((_i + 1))
		done
		if [ "$_late" -eq 1 ]; then
			mrd_log warn "scan: deadline exceeded, parsing what we have"
			break
		fi
		_done=$((_done + 1))
		mrd_sput sys.scan_progress "$((_done * 100 / _nch))"
		# refresh the published status so the UI sees live progress
		[ $((_done % 2)) -eq 0 ] && mrd_status_write
		[ "$_abort" -eq 1 ] && break
	done

	mrd_pid_kill tcpdump

	if [ ! -s "$_cap" ]; then
		mrd_scan_fail "no packets captured" E_SCAN
		return 1
	fi

	if ! "$MRD_LIBEXEC/mrdark-verify" scan-networks "$_cap" --format json \
		>"$MRD_SCAN/networks.json.tmp" 2>"$MRD_SCAN/verify.err"; then
		_rc=$?
		if [ "$_rc" -eq 2 ]; then
			cat "$MRD_SCAN/verify.err" >>"$MRD_LOG" 2>/dev/null
			mrd_scan_fail "scan parse failed" E_SCAN
			return 1
		fi
	fi
	mv -f "$MRD_SCAN/networks.json.tmp" "$MRD_SCAN/networks.json" 2>/dev/null

	_cnt=$(grep -o '"bssid"' "$MRD_SCAN/networks.json" 2>/dev/null | wc -l)
	mrd_sput sys.scan_count "$_cnt"
	rm -f "$MRD_SCAN"/scan*.pcap 2>/dev/null

	# mon0 stays up: re-creating it would kill RX until a driver reload
	mrd_sput sys.scan_progress 100
	mrd_sput sys.scan_state done
	mrd_sput sys.state idle
	mrd_log info "scan finished: $_cnt networks in ${_dur}s"
	mrd_status_write

	[ "$_abort" -eq 1 ] && return 1
	return 0
}

mrd_scan_run "$@"
