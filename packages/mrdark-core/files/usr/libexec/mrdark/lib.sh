#!/bin/sh
# lib.sh - shared helpers for mrdark. Safe to source, no side effects.

MRD_TMP=${MRD_TMP:-/tmp/mrdark}
MRD_LOG=$MRD_TMP/mrdark.log
MRD_STATE=$MRD_TMP/state
MRD_RAW=$MRD_TMP/raw
MRD_SCAN=$MRD_TMP/scan
MRD_RUN=$MRD_TMP/run
MRD_CMD=$MRD_TMP/cmd
MRD_MON=mrdark-mon0
MRD_LIBEXEC=/usr/libexec/mrdark

mrd_now() { date +%s; }

mrd_init_dirs() {
	mkdir -p "$MRD_TMP" "$MRD_STATE" "$MRD_RAW" "$MRD_SCAN" "$MRD_RUN" 2>/dev/null
	if [ -f "$MRD_LOG" ]; then
		_sz=$(wc -c <"$MRD_LOG" 2>/dev/null)
		[ -n "$_sz" ] && [ "$_sz" -gt 262144 ] && mv -f "$MRD_LOG" "$MRD_LOG.1"
	fi
	: >>"$MRD_LOG" 2>/dev/null
}

mrd_log() {
	_lvl=$1
	shift
	printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_lvl" "$*" >>"$MRD_LOG" 2>/dev/null
	case "$_lvl" in
		warn|error) logger -t mrdark "$_lvl: $*" 2>/dev/null ;;
	esac
}

mrd_syslog() { logger -t mrdark "$*" 2>/dev/null; }

# --- config -------------------------------------------------------------

mrd_cfg() {
	_v=$(uci -q get "mrdark.main.$1" 2>/dev/null)
	[ -n "$_v" ] || _v=$2
	printf '%s' "$_v"
}

# per-target value with fallback to global, then to default
mrd_tcfg() {
	_v=$(uci -q get "mrdark.$1.$2" 2>/dev/null)
	[ -n "$_v" ] || _v=$(mrd_cfg "$2" "$3")
	printf '%s' "$_v"
}

# --- runtime state ------------------------------------------------------

mrd_sput() {
	printf '%s' "$2" >"$MRD_STATE/$1" 2>/dev/null
}

mrd_sget() {
	[ -f "$MRD_STATE/$1" ] && cat "$MRD_STATE/$1" 2>/dev/null
}

mrd_sgetd() {
	_v=$(mrd_sget "$1")
	[ -n "$_v" ] || _v=$2
	printf '%s' "$_v"
}

# per-target runtime value: mrd_tget <section> <key> <default>
mrd_tget() {
	_v=$(mrd_sget "t.$1.$2")
	[ -n "$_v" ] || _v=$3
	printf '%s' "$_v"
}

mrd_tset() { mrd_sput "t.$1.$2" "$3"; }

mrd_json_esc() {
	printf '%s' "$1" | tr -d '\r\n' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

mrd_json_str() {
	printf '"%s"' "$(mrd_json_esc "$1")"
}

# empty -> null, else quoted
mrd_json_or_null() {
	if [ -z "$1" ]; then printf 'null'; else mrd_json_str "$1"; fi
}

# --- commands -----------------------------------------------------------

mrd_cmd_peek() {
	[ -f "$MRD_CMD" ] && head -n1 "$MRD_CMD" 2>/dev/null
}

mrd_cmd_take() {
	[ -f "$MRD_CMD" ] || return 1
	mv -f "$MRD_CMD" "$MRD_CMD.work" 2>/dev/null || return 1
	head -n1 "$MRD_CMD.work" 2>/dev/null
	rm -f "$MRD_CMD.work"
}

# sleep in 1s steps; abort early when "stop" is requested.
# returns 0 = slept fully, 1 = aborted
mrd_sleep_chk() {
	_i=0
	while [ "$_i" -lt "$1" ]; do
		case "$(mrd_cmd_peek)" in
			stop*) return 1 ;;
		esac
		sleep 1
		_i=$((_i + 1))
	done
	return 0
}

# ordered list of enabled target sections (uci)
mrd_queue_sections() {
	uci -q show mrdark 2>/dev/null |
		sed -n 's/^mrdark\.\([^=]*\)=target$/\1/p' |
		while read -r s; do
			[ -z "$s" ] && continue
			[ "$(uci -q get "mrdark.$s.enabled" 2>/dev/null)" = "0" ] && continue
			o=$(uci -q get "mrdark.$s.order" 2>/dev/null)
			[ -n "$o" ] || o=0
			printf '%s %s\n' "$o" "$s"
		done | sort -n | awk '{ print $2 }'
}

# run a command with a timeout (busybox has no timeout applet), preserving its
# exit code. returns 124 when the command had to be killed.
mrd_timeout() {
	_secs=$1
	shift
	_rcf="$MRD_RUN/rc.$$"
	rm -f "$_rcf" 2>/dev/null
	( "$@"; echo $? >"$_rcf" ) >/dev/null 2>&1 &
	_tp=$!
	_i=0
	while [ "$_i" -lt "$_secs" ]; do
		if ! kill -0 "$_tp" 2>/dev/null; then
			break
		fi
		sleep 1
		_i=$((_i + 1))
	done
	if kill -0 "$_tp" 2>/dev/null; then
		kill -9 "$_tp" 2>/dev/null
		wait "$_tp" 2>/dev/null
		rm -f "$_rcf" 2>/dev/null
		mrd_log warn "timeout after ${_secs}s: $*"
		return 124
	fi
	wait "$_tp" 2>/dev/null
	_rc=$(cat "$_rcf" 2>/dev/null)
	rm -f "$_rcf" 2>/dev/null
	[ -n "$_rc" ] || _rc=0
	return "$_rc"
}

# wait for a pid to die, at most N seconds; then SIGKILL. never blocks forever.
mrd_wait_pid() {
	_p=$1
	_secs=${2:-3}
	_i=0
	while [ "$_i" -lt "$_secs" ] && kill -0 "$_p" 2>/dev/null; do
		sleep 1
		_i=$((_i + 1))
	done
	if kill -0 "$_p" 2>/dev/null; then
		kill -9 "$_p" 2>/dev/null
		sleep 1
	fi
	return 0
}

# --- misc ---------------------------------------------------------------

mrd_error() {
	mrd_sput err.code "$1"
	mrd_sput err.msg "$2"
	mrd_sput err.at "$(mrd_now)"
	mrd_log error "$1: $2"
}

mrd_clear_error() {
	rm -f "$MRD_STATE/err.code" "$MRD_STATE/err.msg" "$MRD_STATE/err.at" 2>/dev/null
}

mrd_free_mb() {
	df -Pk "$1" 2>/dev/null | awk 'NR==2 { print int($4/1024) }'
}

mrd_lock_acquire() {
	if ! mkdir "$MRD_TMP/lock" 2>/dev/null; then
		_old=$(cat "$MRD_TMP/lock/pid" 2>/dev/null)
		if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
			return 1
		fi
		mrd_log warn "stale lock, taking over"
		rm -rf "$MRD_TMP/lock"
		mkdir "$MRD_TMP/lock" 2>/dev/null || return 1
	fi
	printf '%s' "$$" >"$MRD_TMP/lock/pid"
	return 0
}

mrd_lock_release() {
	rm -rf "$MRD_TMP/lock" 2>/dev/null
}

mrd_pid_write() {
	printf '%s' "$2" >"$MRD_RUN/$1.pid" 2>/dev/null
}

mrd_pid_read() {
	[ -f "$MRD_RUN/$1.pid" ] && cat "$MRD_RUN/$1.pid" 2>/dev/null
}

mrd_pid_kill() {
	_p=$(mrd_pid_read "$1")
	if [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null; then
		kill "$_p" 2>/dev/null
		_i=0
		while [ "$_i" -lt 3 ] && kill -0 "$_p" 2>/dev/null; do
			sleep 1
			_i=$((_i + 1))
		done
		kill -9 "$_p" 2>/dev/null
	fi
	rm -f "$MRD_RUN/$1.pid" 2>/dev/null
}
