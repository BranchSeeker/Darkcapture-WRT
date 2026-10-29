#!/bin/sh
# cleanup.sh - idempotent teardown. Safe to run at any time.

. /usr/libexec/mrdark/lib.sh
. /usr/libexec/mrdark/radio.sh

mrd_init_dirs

mrd_log info "cleanup: tearing down radio state"

mrd_pid_kill tcpdump
mrd_pid_kill aireplay
mrd_pid_kill airodump

if [ "$(mrd_cfg keep_monitor 1)" = "1" ]; then
	# recreating the monitor interface kills RX on rtl8xxxu, so keep it
	mrd_log info "cleanup: keeping $MRD_MON up (keep_monitor=1)"
else
	mrd_mon_down
fi
mrd_radio_restore

rm -f "$MRD_CMD" "$MRD_CMD.work" 2>/dev/null
rm -f "$MRD_RAW"/*.pcap "$MRD_RAW"/*.txt 2>/dev/null

mrd_sput job.phase idle
mrd_sput job.active ""
mrd_sput job.bssid ""
mrd_sput job.essid ""
mrd_sput job.channel ""
mrd_sput job.attempt 0
mrd_sput job.next_run 0
mrd_sput job.deauth_sent 0

[ "$(mrd_sget sys.state)" = "scanning" ] && mrd_sput sys.state idle
mrd_sput sys.scan_state idle
mrd_sput sys.scan_progress 0

mrd_lock_release
exit 0
