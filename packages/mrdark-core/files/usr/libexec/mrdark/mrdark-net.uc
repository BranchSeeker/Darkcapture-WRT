#!/usr/bin/ucode
// mrdark-net.uc - print networks.json as a table sorted by signal
// usage: mrdark-net.uc <networks.json>

import * as fs from 'fs';

if (length(ARGV) < 1) {
	print('usage: mrdark-net.uc <networks.json>\n');
	exit(2);
}

let raw = fs.readfile(ARGV[0]);

if (raw == null) {
	print('no scan result yet\n');
	exit(1);
}

let list = json(raw);

if (type(list) != 'array') {
	print('bad scan result\n');
	exit(2);
}

for (let i = 1; i < length(list); i++) {
	let x = list[i], j = i - 1;

	while (j >= 0 && (list[j].rssi + 0) < (x.rssi + 0)) {
		list[j + 1] = list[j];
		j--;
	}
	list[j + 1] = x;
}

printf('%-18s %-3s %-4s %-20s %-9s %-18s %s\n', 'BSSID', 'CH', 'SIG', 'ESSID', 'ENC', 'AKM', 'CL');
for (let i = 0; i < length(list); i++) {
	let n = list[i];

	printf('%-18s %-3d %-4d %-20s %-9s %-18s %d\n',
		n.bssid, n.channel + 0, n.rssi + 0,
		n.essid != '' ? n.essid : '<hidden>',
		n.enc, n.akm, n.clients + 0);
}

exit(0);
