#!/bin/sh
# radio.sh - radio/monitor helpers. Sourced by worker/scan/attempt/cleanup.
#
# Verified on rtl8xxxu (TL-WN722N v2/v3, USB):
#   * deleting and re-creating the monitor interface kills RX (a few hundred
#     bytes instead of tens of KB);
#   * changing channels on a live monitor interface is fine;
#   * re-enumerating the USB device (authorized 0/1) restores RX in ~10s and is
#     much more reliable than rmmod/modprobe, which can hang on this hypervisor.
# Therefore: the monitor interface is created once and kept (keep_monitor=1 by
# default), and recovery always goes through a USB reset first.

. /usr/libexec/mrdark/lib.sh

mrd_phy_list() {
	iw phy 2>/dev/null | grep '^Wiphy' | awk '{ print $2 }'
}

# monitor support + a 2.4 GHz band present
mrd_phy_ok() {
	_info=$(iw phy "$1" info 2>/dev/null) || return 1
	printf '%s\n' "$_info" | grep -q 'monitor' || return 1
	printf '%s\n' "$_info" | grep -qE '\b24[0-9][0-9]\.0 MHz' || return 1
	return 0
}

mrd_phy_pick() {
	_p=$(mrd_cfg phy auto)
	if [ "$_p" != "auto" ]; then
		mrd_phy_ok "$_p" && { printf '%s' "$_p"; return 0; }
		return 1
	fi
	for _x in $(mrd_phy_list); do
		if mrd_phy_ok "$_x"; then
			printf '%s' "$_x"
			return 0
		fi
	done
	return 1
}

mrd_phy_driver() {
	_p=$1
	[ -d "/sys/class/ieee80211/$_p" ] || _p=$(mrd_phy_pick)
	[ -n "$_p" ] || return 1
	_d=$(readlink -f "/sys/class/ieee80211/$_p/device/driver" 2>/dev/null)
	[ -n "$_d" ] || return 1
	basename "$_d"
}

# true when netifd owns radios on this box
mrd_wireless_busy() {
	_s=$(ubus call network.wireless status 2>/dev/null | tr -d ' \t\r\n')
	[ -n "$_s" ] || return 1
	[ "$_s" = "{}" ] && return 1
	return 0
}

# re-enumerate the USB wifi device
mrd_usb_reset() {
	_dev=""
	for _d in /sys/bus/usb/devices/*/idVendor; do
		_dd=$(dirname "$_d")
		_vid=$(cat "$_d" 2>/dev/null)
		_pid=$(cat "$_dd/idProduct" 2>/dev/null)
		case "$_vid:$_pid" in
			2357:010c|0cf3:9271|0bda:*|148f:*|7392:*)
				_dev=$_dd
				break
				;;
		esac
	done
	[ -n "$_dev" ] || return 1
	[ -w "$_dev/authorized" ] || return 1
	mrd_log info "usb reset: $_dev ($(cat $_dev/idVendor):$(cat $_dev/idProduct))"
	printf '0' >"$_dev/authorized" 2>/dev/null
	sleep 3
	printf '1' >"$_dev/authorized" 2>/dev/null
	# wait until the phy is registered again (up to 40s: firmware load is slow)
	_i=0
	while [ "$_i" -lt 40 ]; do
		sleep 1
		_phy=$(mrd_phy_pick) && [ -n "$_phy" ] && break
		_i=$((_i + 1))
	done
	_phy=$(mrd_phy_pick)
	if [ -z "$_phy" ]; then
		mrd_log warn "usb reset: phy did not come back, trying modprobe"
		_drv=$(mrd_phy_driver "$(mrd_sget sys.phy)")
		[ -n "$_drv" ] && mrd_timeout 10 modprobe "$_drv"
		sleep 3
		_phy=$(mrd_phy_pick)
	fi
	[ -n "$_phy" ] && mrd_sput sys.phy "$_phy"
	return 0
}

mrd_driver_reload() {
	_phy=$(mrd_sget sys.phy)
	[ -n "$_phy" ] || _phy=$(mrd_phy_pick)
	_drv=$(mrd_phy_driver "$_phy")
	[ -n "$_drv" ] || return 1
	mrd_log info "module reload: $_drv"
	mrd_timeout 4 iw dev "$MRD_MON" del
	mrd_timeout 6 rmmod "$_drv"
	sleep 2
	mrd_timeout 10 modprobe "$_drv"
	sleep 5
	rm -f "$MRD_STATE/sys.need_reload" 2>/dev/null
	_phy=$(mrd_phy_pick)
	[ -n "$_phy" ] && mrd_sput sys.phy "$_phy"
	return 0
}

# preferred recovery path; throttled: a repeated reset within 5 minutes usually
# means the USB passthrough is wedged and resetting again makes it worse
mrd_radio_recover() {
	_now=$(mrd_now)
	_last=$(mrd_sget sys.last_recover)
	[ -n "$_last" ] || _last=0
	if [ "$_now" -ge "$_last" ] && [ $((_now - _last)) -lt 300 ]; then
		mrd_log warn "radio recovery skipped: last attempt $((_now - _last))s ago (throttled)"
		return 1
	fi
	mrd_sput sys.last_recover "$_now"
	if mrd_usb_reset; then
		rm -f "$MRD_STATE/sys.need_reload" 2>/dev/null
		return 0
	fi
	mrd_driver_reload
}

mrd_radio_prepare() {
	_phy=$(mrd_phy_pick) || return 1
	mrd_sput sys.phy "$_phy"
	if mrd_wireless_busy; then
		mrd_log warn "netifd holds radios; trying to release $_phy"
		ubus call network.wireless down "{\"device\":\"$_phy\"}" >/dev/null 2>&1
		mrd_sput sys.radio_was_busy 1
		if mrd_wireless_busy; then
			mrd_error E_RADIO_BUSY "network.wireless still owns the radio; disable wireless on $_phy"
			return 2
		fi
	fi
	return 0
}

mrd_mon_up() {
	_phy=$1
	[ -n "$_phy" ] || return 1
	mrd_timeout 5 iw phy "$_phy" interface add "$MRD_MON" type monitor || return 1
	mrd_timeout 3 ip link set "$MRD_MON" up
	iw dev "$MRD_MON" info 2>/dev/null | grep -q 'type monitor' || return 1
	return 0
}

mrd_mon_is_up() {
	mrd_timeout 3 iw dev "$MRD_MON" info
}

mrd_mon_down() {
	if mrd_mon_is_up; then
		mrd_timeout 4 iw dev "$MRD_MON" del
		mrd_sput sys.need_reload 1
	fi
	return 0
}

mrd_mon_ensure() {
	if [ "$(mrd_sget sys.need_reload)" = "1" ]; then
		mrd_radio_recover
	fi
	if mrd_mon_is_up; then
		return 0
	fi
	# creation can fail right after a usb re-enumeration: retry a few times
	_i=0
	while [ "$_i" -lt 8 ]; do
		_phy=$(mrd_phy_pick) || { _i=$((_i + 1)); sleep 4; continue; }
		mrd_sput sys.phy "$_phy"
		if mrd_mon_up "$_phy"; then
			return 0
		fi
		_i=$((_i + 1))
		mrd_log warn "cannot create $MRD_MON on $_phy (attempt $_i), retrying"
		sleep 4
	done
	return 1
}

mrd_set_channel() {
	_ch=$1
	[ -n "$_ch" ] && [ "$_ch" != "0" ] || return 1
	mrd_timeout 4 iw dev "$MRD_MON" set channel "$_ch" && return 0
	mrd_timeout 4 iw dev "$MRD_MON" set channel "$_ch" HT20 && return 0
	return 1
}

mrd_mon_channel() {
	iw dev "$MRD_MON" info 2>/dev/null | sed -n 's/.*channel \([0-9]*\) (\([0-9]*\) MHz).*/\1/p'
}

# quick RX sanity check: a few seconds of capture must produce frames
mrd_mon_health() {
	# a freshly created monitor interface has no channel yet and would
	# receive nothing, which would look like a dead radio
	if [ -z "$(mrd_mon_channel)" ]; then
		mrd_set_channel 6 || mrd_set_channel 1
	fi
	_f="$MRD_RUN/health.pcap"
	rm -f "$_f" 2>/dev/null
	tcpdump -i "$MRD_MON" -c 5 -w "$_f" >/dev/null 2>&1 &
	_hp=$!
	sleep 3
	kill "$_hp" >/dev/null 2>&1
	mrd_wait_pid "$_hp" 2
	_sz=$(wc -c <"$_f" 2>/dev/null || echo 0)
	rm -f "$_f" 2>/dev/null
	[ "$_sz" -gt 40 ]
}

mrd_radio_restore() {
	_phy=$(mrd_sget sys.phy)
	if [ "$(mrd_sget sys.radio_was_busy)" = "1" ] && [ -n "$_phy" ]; then
		ubus call network.wireless up "{\"device\":\"$_phy\"}" >/dev/null 2>&1
	fi
	rm -f "$MRD_STATE/sys.radio_was_busy" 2>/dev/null
	return 0
}
