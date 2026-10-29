'use strict';
// mrdark rpcd plugin: exposes the `mrdark` ubus object for LuCI.
// The worker does the heavy lifting; this plugin only reads runtime state and
// writes one line commands into /tmp/mrdark/cmd.
//
// Note: arguments are declared as String because that is the only type this
// rpcd build accepts reliably; JSON is passed as a string where needed.

import { readfile, writefile, lsdir, unlink, stat, popen } from 'fs';
import { cursor } from 'uci';

const STATUS = '/tmp/mrdark/status.json';
const NETWORKS = '/tmp/mrdark/scan/networks.json';
const CMD = '/tmp/mrdark/cmd';
const LOG = '/tmp/mrdark/mrdark.log';
const STATE = '/tmp/mrdark/state';

const RE_MAC = regexp('^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$');
const RE_KEY = regexp('^[a-z_]+$');

const ALLOWED_SETTINGS = [
	'phy', 'artifacts_dir', 'storage_max_mb',
	'scan_duration', 'attempt_window', 'deauth_count', 'deauth_bursts', 'caps_target',
	'retry_interval', 'success_interval', 'max_fails_in_row',
	'max_attempts_total', 'cyclic_pause', 'deauth_mode', 'hc22000',
	'on_finish', 'autostart', 'log_level', 'confirm_authorized'
];

// per-target overrides; empty value means "inherit from main"
const TARGET_OVERRIDES = [
	'deauth_count', 'deauth_bursts', 'caps_target', 'retry_interval', 'success_interval',
	'attempt_window', 'max_fails_in_row', 'max_attempts_total'
];

function cur() {
	const c = cursor();

	c.load('mrdark');

	return c;
}

// drop runtime counters/status of one target: the section name is derived from
// the BSSID, so without this a re-added network would inherit "closed"/caps
// from the previous run
function reset_target_state(section) {
	const files = lsdir(STATE) ?? [];
	const prefix = section + '.';

	for (let i = 0; i < length(files); i++)
		if (substr(files[i], 0, length(prefix)) == prefix)
			unlink(STATE + '/' + files[i]);
}

function read_json(path) {
	const raw = readfile(path);

	if (raw == null)
		return null;

	return json(raw);
}

function send_cmd(cmd) {
	if (writefile(CMD, cmd + '\n') == null)
		return { ok: false, error: 'cannot write ' + CMD };

	return { ok: true };
}

function main_section() {
	const all = cur().get_all('mrdark');

	return (all != null && all.main != null) ? all.main : {};
}

function targets() {
	const all = cur().get_all('mrdark') ?? {};
	const list = [];

	for (let s in all) {
		const sec = all[s];

		if (sec == null || sec.bssid == null)
			continue;

		const item = {
			section: s,
			bssid: sec.bssid,
			essid: sec.essid ?? '',
			channel: sec.channel ?? '',
			order: int(sec.order ?? 0),
			enabled: (sec.enabled ?? '1') != '0'
		};

		for (let i = 0; i < length(TARGET_OVERRIDES); i++) {
			const k = TARGET_OVERRIDES[i];

			item[k] = sec[k] ?? '';
		}

		push(list, item);
	}

	return sort(list, (a, b) => (a.order - b.order));
}

function apply_overrides(c, section, opts_json) {
	if (opts_json == null || opts_json == '')
		return true;

	const o = json(opts_json) ?? {};

	if (type(o) != 'object')
		return false;

	for (let i = 0; i < length(TARGET_OVERRIDES); i++) {
		const k = TARGET_OVERRIDES[i];

		if (o[k] == null)
			continue;

		const v = '' + o[k];

		if (v == '')
			c.delete('mrdark', section, k);
		else
			c.set('mrdark', section, k, v);
	}

	return true;
}

function find_target(bssid) {
	const all = cur().get_all('mrdark') ?? {};
	const want = uc(bssid);

	for (let s in all)
		if (all[s] != null && uc(all[s].bssid ?? '') == want)
			return s;

	return null;
}

function settings() {
	const main = main_section();
	const out = {};

	for (let i = 0; i < length(ALLOWED_SETTINGS); i++) {
		const k = ALLOWED_SETTINGS[i];

		out[k] = main[k] ?? '';
	}

	return out;
}

function artifacts() {
	const dir = main_section().artifacts_dir ?? '/root/cap';
	const out = [];
	const subdirs = lsdir(dir) ?? [];

	for (let i = 0; i < length(subdirs); i++) {
		const sd = subdirs[i];

		if (sd == '.' || sd == '..')
			continue;

		const sub = dir + '/' + sd;
		const files = lsdir(sub) ?? [];

		for (let j = 0; j < length(files); j++) {
			const f = files[j];

			if (f == '.' || f == '..')
				continue;

			const st = stat(sub + '/' + f);

			if (st == null || st.type != 'file')
				continue;

			push(out, {
				path: sub + '/' + f,
				name: f,
				essid_dir: sd,
				size: st.size ?? 0,
				mtime: st.mtime ?? 0
			});
		}
	}

	return sort(out, (a, b) => (b.mtime - a.mtime));
}

function tail_lines(path, count) {
	const raw = readfile(path);

	if (raw == null)
		return [];

	const lines = split(raw, '\n');

	if (length(lines) > count)
		splice(lines, 0, length(lines) - count);

	return lines;
}

const methods = {
	job_status: {
		call: function() {
			const st = read_json(STATUS);

			if (st == null)
				return { version: 1, state: 'offline', job: {}, queue: [], counters: {}, storage: {}, scan: {} };

			return st;
		}
	},

	scan_start: {
		call: function() {
			// mark the request as pending right away, otherwise a poller can
			// read the previous "done" state and think nothing happened
			writefile(STATE + '/sys.scan_state', 'queued');
			writefile(STATE + '/sys.scan_progress', '0');
			return send_cmd('scan');
		}
	},

	scan_status: {
		call: function() {
			const st = read_json(STATUS);

			return (st != null && st.scan != null) ? st.scan : { state: 'idle', progress: 0, count: 0 };
		}
	},

	scan_results: {
		call: function() {
			const list = read_json(NETWORKS);

			return { networks: (type(list) == 'array') ? list : [] };
		}
	},

	targets_list: {
		call: function() { return { targets: targets() }; }
	},

	target_add: {
		args: { bssid: 'String', essid: 'String', channel: 'String', opts: 'String' },
		call: function(req) {
			const bssid = req.args.bssid ?? '';

			if (!match(bssid, RE_MAC))
				return { ok: false, error: 'bad bssid' };

			const c = cur();
			const mac = uc(bssid);
			let section = find_target(mac);

			if (section == null) {
				section = c.add('mrdark', 'target');

				if (section == null || section == '')
					return { ok: false, error: 'cannot create section' };

				// an anonymous uci section is visible to the shell as
				// "@target[N]", so give it the same stable name the CLI uses
				const want = 't_' + lc(replace(mac, ':', ''));

				if (section != want) {
					if (!c.rename('mrdark', section, want)) {
						c.delete('mrdark', section);
						return { ok: false, error: 'cannot rename section' };
					}
					section = want;
				}

				c.set('mrdark', section, 'order', '' + length(targets()));
			}

			c.set('mrdark', section, 'bssid', mac);
			c.set('mrdark', section, 'essid', req.args.essid ?? '');
			c.set('mrdark', section, 'channel', req.args.channel ?? '');
			c.set('mrdark', section, 'enabled', '1');

			if (!apply_overrides(c, section, req.args.opts))
				return { ok: false, error: 'bad opts' };

			if (!c.commit('mrdark'))
				return { ok: false, error: 'commit failed' };

			// a (re-)added target always starts from a clean slate
			reset_target_state(section);
			send_cmd('reload');

			return { ok: true, section: section };
		}
	},

	target_update: {
		args: { section: 'String', essid: 'String', channel: 'String', opts: 'String' },
		call: function(req) {
			const c = cur();
			const sec = req.args.section ?? '';

			if (c.get('mrdark', sec, 'bssid') == null)
				return { ok: false, error: 'no such target' };

			if (req.args.essid != null)
				c.set('mrdark', sec, 'essid', req.args.essid);
			if (req.args.channel != null)
				c.set('mrdark', sec, 'channel', req.args.channel);

			if (!apply_overrides(c, sec, req.args.opts))
				return { ok: false, error: 'bad opts' };

			if (!c.commit('mrdark'))
				return { ok: false, error: 'commit failed' };

			send_cmd('reload');

			return { ok: true };
		}
	},

	target_delete: {
		args: { section: 'String' },
		call: function(req) {
			const c = cur();
			const sec = req.args.section ?? '';

			if (c.get('mrdark', sec, 'bssid') == null)
				return { ok: false, error: 'no such target' };

			c.delete('mrdark', sec);

			if (!c.commit('mrdark'))
				return { ok: false, error: 'commit failed' };

			// forget counters/status, keep the artefact files on disk
			reset_target_state(sec);
			send_cmd('reload');

			return { ok: true };
		}
	},

	// stop the job, drop every target and its runtime history; artefact files
	// on disk are intentionally left untouched
	queue_clear: {
		call: function() {
			const c = cur();
			const all = c.get_all('mrdark') ?? {};
			const removed = [];

			for (let s in all)
				if (all[s] != null && all[s].bssid != null) {
					c.delete('mrdark', s);
					reset_target_state(s);
					push(removed, s);
				}

			// wipe any remaining per-target runtime files
			const files = lsdir(STATE) ?? [];

			for (let i = 0; i < length(files); i++)
				if (substr(files[i], 0, 2) == 't.')
					unlink(STATE + '/' + files[i]);

			if (!c.commit('mrdark'))
				return { ok: false, error: 'commit failed' };

			writefile(CMD, 'stop\n');

			return { ok: true, removed: removed };
		}
	},

	queue_reorder: {
		args: { order: 'String' },
		call: function(req) {
			const c = cur();
			const list = split(req.args.order ?? '', ',');

			for (let i = 0; i < length(list); i++)
				if (list[i] != '')
					c.set('mrdark', list[i], 'order', '' + i);

			if (!c.commit('mrdark'))
				return { ok: false, error: 'commit failed' };

			send_cmd('reload');

			return { ok: true };
		}
	},

	job_start: { call: function() { return send_cmd('start'); } },
	job_stop: { call: function() { return send_cmd('stop'); } },
	job_pause: { call: function() { return send_cmd('pause'); } },
	job_resume: { call: function() { return send_cmd('resume'); } },
	job_skip: { call: function() { return send_cmd('skip'); } },
	job_recover: { call: function() { return send_cmd('recover'); } },

	artifacts_list: {
		call: function() { return { artifacts: artifacts() }; }
	},

	artifact_delete: {
		args: { path: 'String' },
		call: function(req) {
			const dir = main_section().artifacts_dir ?? '/root/cap';
			const p = req.args.path ?? '';

			if (substr(p, 0, length(dir) + 1) != dir + '/')
				return { ok: false, error: 'path outside artefacts dir' };

			if (unlink(p) == null)
				return { ok: false, error: 'cannot delete' };

			return { ok: true };
		}
	},

	settings_get: {
		call: function() { return { settings: settings() }; }
	},

	settings_set: {
		args: { settings: 'String' },
		call: function(req) {
			const c = cur();
			const s = json(req.args.settings ?? '{}') ?? {};
			const changed = [];

			for (let k in s) {
				if (!match(k, RE_KEY))
					continue;
				if (index(ALLOWED_SETTINGS, k) < 0)
					continue;

				c.set('mrdark', 'main', k, '' + s[k]);
				push(changed, k);
			}

			if (length(changed) == 0)
				return { ok: false, error: 'nothing to set' };
			if (!c.commit('mrdark'))
				return { ok: false, error: 'commit failed' };

			return { ok: true, changed: changed };
		}
	},

	log_tail: {
		args: { lines: 'String' },
		call: function(req) {
			let n = int(req.args.lines ?? 50);

			if (n < 1)
				n = 50;
			if (n > 500)
				n = 500;

			return { lines: tail_lines(LOG, n) };
		}
	},

	radio_status: {
		call: function() {
			const fd = popen('iw phy 2>/dev/null | sed -n "s/^Wiphy //p"');
			const list = [];

			if (fd == null)
				return { phys: list };

			const out = split(fd.read('all') ?? '', '\n');

			fd.close();

			for (let i = 0; i < length(out); i++)
				if (out[i] != '')
					push(list, out[i]);

			return { phys: list };
		}
	}
};

return { mrdark: methods };
