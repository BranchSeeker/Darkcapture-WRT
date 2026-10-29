#!/usr/bin/ucode
// mrdark-status.uc - human readable view of /tmp/mrdark/status.json
// usage: mrdark-status.uc [now_epoch]

import * as fs from 'fs';

let raw = fs.readfile('/tmp/mrdark/status.json');

if (raw == null) {
	print('worker is not running (no status.json)\n');
	exit(1);
}

let st = json(raw);

if (st == null) {
	print('cannot parse status.json\n');
	exit(2);
}

function fmt(v) {
	if (v == null)
		return '-';
	if (type(v) == 'string' && v == '')
		return '-';

	return v;
}

let now = (length(ARGV) > 0) ? int(ARGV[0]) : 0;

printf('state:    %s\n', fmt(st.state));
printf('phase:    %s\n', fmt(st.job.phase));
printf('target:   %s / %s ch %s\n', fmt(st.job.active_essid), fmt(st.job.active_bssid), fmt(st.job.channel));
printf('attempt:  %s  round: %s\n', fmt(st.job.attempt), fmt(st.job.round));
printf('caps:     %s  attempts: %s\n', fmt(st.counters.caps_total), fmt(st.counters.attempts_total));

if (now > 0 && st.job.next_run_at > 0) {
	let left = st.job.next_run_at - now;
	printf('next run: in %d s\n', (left > 0) ? left : 0);
}

if (st.last_error != null)
	printf('error:    %s - %s\n', st.last_error.code, st.last_error.msg);

printf('storage:  scratch %s MB free, artefacts %s MB\n', fmt(st.storage.scratch_free_mb), fmt(st.storage.artifacts_mb));
printf('log:      %s\n', fmt(st.log_file));

if (length(st.queue) > 0) {
	printf('\nqueue:\n');
	for (let i = 0; i < length(st.queue); i++) {
		let q = st.queue[i];

		printf('  %-22s %-18s %-9s caps=%-3d attempts=%d\n',
			fmt(q.section), fmt(q.bssid), fmt(q.state), q.caps + 0, q.attempts + 0);
	}
}

exit(0);
