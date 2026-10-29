#!/bin/sh
# status.sh - builds /tmp/mrdark/status.json (atomic) and small helpers.

. /usr/libexec/mrdark/lib.sh

mrd_queue_json() {
	_more=
	printf '['
	for _s in $(mrd_queue_sections); do
		printf '%s' "$_more"
		_more=,
		_bs=$(uci -q get "mrdark.$_s.bssid" 2>/dev/null)
		_es=$(uci -q get "mrdark.$_s.essid" 2>/dev/null)
		_re=$(mrd_sget "t.$_s.reason")
		printf '{"section":"%s","bssid":%s,"essid":%s,"state":"%s","caps":%s,"attempts":%s,"fails_in_row":%s,"closed_reason":%s}' \
			"$_s" \
			"$(mrd_json_str "$_bs")" \
			"$(mrd_json_str "$_es")" \
			"$(mrd_tget "$_s" status pending)" \
			"$(mrd_tget "$_s" caps 0)" \
			"$(mrd_tget "$_s" attempts 0)" \
			"$(mrd_tget "$_s" fails 0)" \
			"$(mrd_json_or_null "$_re")"
	done
	printf ']'
}

mrd_counters() {
	_caps=0
	_att=0
	for _s in $(mrd_queue_sections); do
		_caps=$((_caps + $(mrd_tget "$_s" caps 0)))
		_att=$((_att + $(mrd_tget "$_s" attempts 0)))
	done
	printf '%s %s' "$_caps" "$_att"
}

# du of the artefacts dir, throttled to once per 10s
mrd_artifacts_mb() {
	_dir=$(mrd_cfg artifacts_dir /root/cap)
	_ts=$(mrd_sget sys.storage_ts)
	_val=$(mrd_sget sys.storage_mb)
	_now=$(mrd_now)
	if [ -z "$_ts" ] || [ $((_now - _ts)) -ge 10 ] || [ -z "$_val" ]; then
		_val=$(du -sk "$_dir" 2>/dev/null | awk '{ print $1 }')
		[ -n "$_val" ] || _val=0
		_val=$(awk -v k="$_val" 'BEGIN { printf "%.1f", k/1024 }')
		mrd_sput sys.storage_mb "$_val"
		mrd_sput sys.storage_ts "$_now"
	fi
	printf '%s' "$_val"
}

mrd_error_json() {
	_c=$(mrd_sget err.code)
	if [ -z "$_c" ]; then
		printf 'null'
		return
	fi
	printf '{"code":%s,"msg":%s,"at":%s}' \
		"$(mrd_json_str "$_c")" \
		"$(mrd_json_str "$(mrd_sget err.msg)")" \
		"$(mrd_sgetd err.at 0)"
}

mrd_status_write() {
	_t=$(mrd_now)
	_act=$(mrd_sget job.active)
	_scratch=$(mrd_cfg scratch_dir /tmp/mrdark)
	set -- $(mrd_counters)
	_caps=$1
	_att=$2
	{
		printf '{"version":1,"state":"%s","updated_at":%s,"started_at":%s,' \
			"$(mrd_sgetd sys.state idle)" "$_t" "$(mrd_sgetd sys.started 0)"
		printf '"scan":{"state":"%s","progress":%s,"count":%s,"started_at":%s,"error":%s},' \
			"$(mrd_sgetd sys.scan_state idle)" \
			"$(mrd_sgetd sys.scan_progress 0)" \
			"$(mrd_sgetd sys.scan_count 0)" \
			"$(mrd_sgetd sys.scan_started 0)" \
			"$(mrd_json_or_null "$(mrd_sget sys.scan_error)")"
		printf '"job":{"phase":"%s","active_section":%s,"active_bssid":%s,"active_essid":%s,"channel":"%s","attempt":%s,"next_run_at":%s,"round":%s,"on_finish":"%s"},' \
			"$(mrd_sgetd job.phase idle)" \
			"$(mrd_json_or_null "$_act")" \
			"$(mrd_json_or_null "$(mrd_sget job.bssid)")" \
			"$(mrd_json_or_null "$(mrd_sget job.essid)")" \
			"$(mrd_sget job.channel)" \
			"$(mrd_sgetd job.attempt 0)" \
			"$(mrd_sgetd job.next_run 0)" \
			"$(mrd_sgetd job.round 1)" \
			"$(mrd_cfg on_finish idle)"
		printf '"queue":%s,' "$(mrd_queue_json)"
		printf '"counters":{"caps_total":%s,"attempts_total":%s},' "$_caps" "$_att"
		printf '"storage":{"scratch_free_mb":%s,"artifacts_mb":%s},' \
			"$(mrd_free_mb "$_scratch")" "$(mrd_artifacts_mb)"
		printf '"last_error":%s,' "$(mrd_error_json)"
		printf '"log_file":"%s"}\n' "$MRD_LOG"
	} >"$MRD_TMP/status.json.tmp" 2>/dev/null &&
		mv -f "$MRD_TMP/status.json.tmp" "$MRD_TMP/status.json" 2>/dev/null
}
