'use strict';
'require view';
'require rpc';
'require poll';
'require ui';
'require dom';
'require fs';

var callStatus = rpc.declare({ object: 'mrdark', method: 'job_status', expect: {} });
var callScanStart = rpc.declare({ object: 'mrdark', method: 'scan_start', expect: {} });
var callScanResults = rpc.declare({ object: 'mrdark', method: 'scan_results' });
var callTargets = rpc.declare({ object: 'mrdark', method: 'targets_list' });
var callTargetAdd = rpc.declare({ object: 'mrdark', method: 'target_add', params: [ 'bssid', 'essid', 'channel', 'opts' ], expect: {} });
var callTargetDelete = rpc.declare({ object: 'mrdark', method: 'target_delete', params: [ 'section' ], expect: {} });
var callJobStart = rpc.declare({ object: 'mrdark', method: 'job_start', expect: {} });
var callJobStop = rpc.declare({ object: 'mrdark', method: 'job_stop', expect: {} });
var callQueueClear = rpc.declare({ object: 'mrdark', method: 'queue_clear', expect: {} });
var callJobPause = rpc.declare({ object: 'mrdark', method: 'job_pause', expect: {} });
var callJobResume = rpc.declare({ object: 'mrdark', method: 'job_resume', expect: {} });
var callJobSkip = rpc.declare({ object: 'mrdark', method: 'job_skip', expect: {} });
var callArtifacts = rpc.declare({ object: 'mrdark', method: 'artifacts_list' });
var callArtifactDelete = rpc.declare({ object: 'mrdark', method: 'artifact_delete', params: [ 'path' ], expect: {} });
var callLogTail = rpc.declare({ object: 'mrdark', method: 'log_tail', params: [ 'lines' ] });
var callSettingsGet = rpc.declare({ object: 'mrdark', method: 'settings_get' });
var callSettingsSet = rpc.declare({ object: 'mrdark', method: 'settings_set', params: [ 'settings' ], expect: {} });
var callFileReadB64 = rpc.declare({ object: 'file', method: 'read', params: [ 'path', 'base64' ], expect: {} });

var SETTINGS_FIELDS = [
	[ 'deauth_count', 'Deauth packets per attempt', 'number' ],
	[ 'deauth_bursts', 'Deauth bursts (1-3)', 'number' ],
	[ 'caps_target', 'Valid captures per target', 'number' ],
	[ 'retry_interval', 'Retry interval, s', 'number' ],
	[ 'success_interval', 'Interval after success, s', 'number' ],
	[ 'attempt_window', 'Capture window, s', 'number' ],
	[ 'max_fails_in_row', 'Max failures in a row', 'number' ],
	[ 'max_attempts_total', 'Max attempts per target', 'number' ],
	[ 'cyclic_pause', 'Pause between rounds, s', 'number' ],
	[ 'scan_duration', 'Scan duration, s', 'number' ],
	[ 'deauth_mode', 'Deauth mode (auto/broadcast/targeted)', 'text' ],
	[ 'hc22000', 'hc22000 conversion (auto/always/never)', 'text' ],
	[ 'on_finish', 'On finish (idle/halt/reboot)', 'text' ],
	[ 'artifacts_dir', 'Artefacts directory', 'text' ],
	[ 'storage_max_mb', 'Maximum artefacts size, MB', 'number' ]
];

function btn(label, cls, fn) {
	return E('button', {
		'class': 'btn cbi-button ' + (cls || 'cbi-button-neutral'),
		'click': ui.createHandlerFn(this, fn)
	}, [ label ]);
}

// notification that hides itself after a couple of seconds
function notify(msg, kind) {
	var node = ui.addNotification(null, E('p', {}, [ msg ]), kind || 'info');

	if (node && node.parentNode)
		setTimeout(function() {
			try { node.parentNode.removeChild(node); } catch (e) { }
		}, 2500);

	return node;
}

function fmtTime(ts) {
	if (!ts)
		return '—';

	var d = new Date(ts * 1000);

	return d.toLocaleString();
}

function fmtDur(s) {
	s = parseInt(s) || 0;

	if (s <= 0)
		return '—';

	var m = Math.floor(s / 60);

	return (m > 0 ? m + ' min ' : '') + (s % 60) + ' s';
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			callScanResults(),
			callTargets(),
			callSettingsGet(),
			callLogTail('200')
		]);
	},

	render: function(data) {
		var self = this;
		var status = data[0] || {};
		var networks = (data[1] || {}).networks || [];
		var targets = (data[2] || {}).targets || [];
		var settings = (data[3] || {}).settings || {};
		var loglines = (data[4] || {}).lines || [];

		var activeTab = 0;
		var panes = [];
		var tabButtons = [];

		function switchTab(i) {
			activeTab = i;

			for (var j = 0; j < panes.length; j++)
				panes[j].style.display = (i === j) ? '' : 'none';

			for (var k = 0; k < tabButtons.length; k++)
				tabButtons[k].className = (i === k) ? 'btn cbi-button cbi-button-action' : 'btn cbi-button cbi-button-neutral';
		}

		function makeTab(title, index) {
			var b = E('button', {
				'class': 'btn cbi-button cbi-button-neutral',
				'click': function() { switchTab(index); }
			}, [ title ]);

			tabButtons.push(b);

			return b;
		}

		/* ---------------------------------------------------------- scan tab */

		var scanInfo = E('div', { 'class': 'cbi-value-description' }, [ 'Не выполнялось' ]);
		var scanTable = E('div', {}, []);
		var scanProgress = E('div', {}, []);

		function openTargetModal(net) {
			var essidAttrs = {
				'class': 'cbi-input-text',
				'value': net.essid || ''
			};

			if (net.essid)
				essidAttrs.readonly = 'readonly';

			var essidInput = E('input', essidAttrs);
			var existing = null;

			(targets || []).forEach(function(t) {
				if (t.bssid && net.bssid && t.bssid.toUpperCase() === net.bssid.toUpperCase())
					existing = t;
			});

			function eff(k, fallback) {
				return (existing && existing[k]) ? existing[k] : fallback;
			}

			function collectOpts() {
				return JSON.stringify({
					deauth_count: String(parseInt(deauth.value) || 20),
					caps_target: String(parseInt(caps.value) || 100),
					retry_interval: String((parseInt(retry.value) || 3) * 60),
					success_interval: String((parseInt(success.value) || 5) * 60)
				});
			}

			var deauth = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'value': String(eff('deauth_count', settings.deauth_count || '20')) });
			var caps = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'value': String(eff('caps_target', settings.caps_target || '100')) });
			var retry = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'value': String(Math.round((parseInt(eff('retry_interval', settings.retry_interval || '180')) || 180) / 60)) });
			var success = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'value': String(Math.round((parseInt(eff('success_interval', settings.success_interval || '300')) || 300) / 60)) });

			var body = E('div', {}, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'ESSID' ]),
					E('div', { 'class': 'cbi-value-field' }, [ essidInput ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'BSSID' ]),
					E('div', { 'class': 'cbi-value-field' }, [ E('span', {}, [ net.bssid ]) ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Канал' ]),
					E('div', { 'class': 'cbi-value-field' }, [ E('span', {}, [ String(net.channel) ]) ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Deauth-пакетов' ]),
					E('div', { 'class': 'cbi-value-field' }, [ deauth ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Валидных захватов' ]),
					E('div', { 'class': 'cbi-value-field' }, [ caps ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Интервал между прогонами, мин' ]),
					E('div', { 'class': 'cbi-value-field' }, [ retry ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ 'Интервал после успеха, мин' ]),
					E('div', { 'class': 'cbi-value-field' }, [ success ])
				])
			]);

			if (net.pmf_required)
				body.appendChild(E('div', { 'class': 'alert-message warning' }, [
					'Сеть требует PMF (802.11w) — deauth, скорее всего, не сработает. Захват возможен только при переподключении клиента.'
				]));

			var overlay = E('div', {
				'style': 'position:fixed;top:0;left:0;right:0;bottom:0;background:rgba(0,0,0,.45);z-index:1200;display:flex;align-items:center;justify-content:center'
			}, [ E('div', { 'class': 'cbi-modal', 'style': 'background:#fff;padding:1.5rem;border-radius:6px;min-width:420px;max-width:90vw' }, [
				E('h3', {}, [ 'Настройка захвата: ' + (net.essid || net.bssid) ]),
				body,
				E('div', { 'class': 'cbi-button-row', 'style': 'margin-top:1rem;text-align:right' }, [
					E('button', { 'class': 'btn cbi-button cbi-button-neutral', 'click': function() { document.body.removeChild(overlay); } }, [ 'Отмена' ]),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(self, function() {
						var ess = essidInput.value;

						if (!ess && !net.essid) {
							notify('Для скрытой сети нужен ESSID', 'warning');
							return;
						}

						return callTargetAdd(net.bssid, ess || net.essid || '', String(net.channel), collectOpts()).then(function(r) {
							document.body.removeChild(overlay);

							if (!r || r.ok === false) {
								notify('Ошибка: ' + ((r && r.error) || 'unknown'), 'danger');
								return;
							}

							notify('Цель добавлена в очередь', 'info');
							return self.refreshAll();
						});
					}) }, [ 'В очередь' ]),
					' ',
					E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': ui.createHandlerFn(self, function() {
						var ess = essidInput.value || net.essid || '';

						return callTargetAdd(net.bssid, ess, String(net.channel), collectOpts()).then(function() {
							return callJobStart();
						}).then(function(r) {
							document.body.removeChild(overlay);

							if (!r || r.ok === false)
								notify('Не удалось запустить: ' + ((r && r.error) || 'см. лог'), 'danger');
							else
								notify('Задача запущена', 'info');

							return self.refreshAll();
						});
					}) }, [ 'Запустить сейчас' ])
				])
			]) ]);

			document.body.appendChild(overlay);
		}

		function renderNetworks(list) {
			list = (list || []).slice().sort(function(a, b) { return (b.rssi || 0) - (a.rssi || 0); });

			if (!list.length) {
				scanTable.innerHTML = '';
				scanTable.appendChild(E('p', { 'class': 'cbi-value-description' }, [ 'Сети не найдены — запустите сканирование' ]));
				return;
			}

			var rows = [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ 'SSID' ]),
				E('th', { 'class': 'th' }, [ 'BSSID' ]),
				E('th', { 'class': 'th' }, [ 'CH' ]),
				E('th', { 'class': 'th' }, [ 'Сигнал' ]),
				E('th', { 'class': 'th' }, [ 'Шифрование' ]),
				E('th', { 'class': 'th' }, [ 'Клиенты' ])
			]) ];

			list.forEach(function(n) {
				var label = n.essid || '«скрытая»';
				var badges = [];

				if (n.pmf_required)
					badges.push(E('span', { 'class': 'label', 'style': 'margin-left:.4rem;font-size:.8em;background:#e8a33d;color:#fff;border-radius:3px;padding:0 .3rem' }, [ 'PMF' ]));
				if (n.is_5ghz)
					badges.push(E('span', { 'class': 'label', 'style': 'margin-left:.4rem;font-size:.8em;background:#888;color:#fff;border-radius:3px;padding:0 .3rem' }, [ '5G' ]));

				rows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [
						E('a', { 'href': '#', 'click': ui.createHandlerFn(self, function(ev) { ev.preventDefault(); openTargetModal(n); }) }, [ label ]),
						badges
					]),
					E('td', { 'class': 'td' }, [ n.bssid ]),
					E('td', { 'class': 'td' }, [ String(n.channel) ]),
					E('td', { 'class': 'td' }, [ String(n.rssi) + ' dBm' ]),
					E('td', { 'class': 'td' }, [ n.enc || (n.privacy ? 'WPA' : 'OPEN') ]),
					E('td', { 'class': 'td' }, [ String(n.clients || 0) ])
				]));
			});

			scanTable.innerHTML = '';
			scanTable.appendChild(E('table', { 'class': 'table' }, rows));
		}

		function startScan() {
			scanProgress.innerHTML = '';
			scanProgress.appendChild(E('em', {}, [ 'Сканирование…' ]));

			return callScanStart().then(function() {
				var tries = 0;
				return new Promise(function(resolve) {
					var iv = setInterval(function() {
						tries++;
						callStatus().then(function(s) {
							var sc = (s && s.scan) || {};

							if (sc.state === 'done' || sc.state === 'error' || tries > 120) {
								clearInterval(iv);
								scanProgress.innerHTML = '';
								scanInfo.innerHTML = '';
								scanInfo.appendChild(E('span', {}, [
									'Сканирование: ' + (sc.state || '?') + ', сетей: ' + (sc.count || 0) + (sc.error ? (', ошибка: ' + sc.error) : '')
								]));
								callScanResults().then(function(r) {
									var got = (r || {}).networks || [];

									if (!got.length)
										notify('scan_results вернул пустой список (проверьте лог)', 'warning');
									renderNetworks(got);
								});
								resolve();
							}
							else {
								scanProgress.innerHTML = '';
								scanProgress.appendChild(E('em', {}, [ 'Сканирование… ' + (sc.progress || 0) + '%' ]));
							}
						});
					}, 1000);
				});
			});
		}

		var scanPane = E('div', {}, [
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ 'Сканирование эфира (2.4 ГГц)' ]),
				E('p', { 'class': 'cbi-value-description' }, [
					'Радио переводится в monitor-режим на время сканирования. Собственная точка доступа на этом радио на время работы недоступна.'
				]),
				E('div', { 'class': 'cbi-button-row' }, [ btn('Сканировать', 'cbi-button-action', startScan) ]),
				scanProgress,
				scanInfo
			]),
			E('div', { 'class': 'cbi-section' }, [ scanTable ])
		]);

		/* ----------------------------------------------------------- job tab */

		var statusCard = E('div', { 'class': 'cbi-section' }, []);
		var queueTable = E('div', { 'class': 'cbi-section' }, []);
		var logBox = E('pre', { 'style': 'max-height:260px;overflow:auto;font-size:.85em;background:#f5f5f5;padding:.5rem' }, [ (loglines || []).join('\n') ]);

		function renderStatus(s) {
			s = s || {};

			var job = s.job || {};
			var cnt = s.counters || {};
			var left = '—';

			if (job.next_run_at) {
				var d = parseInt(job.next_run_at) - Math.floor(Date.now() / 1000);

				left = (d > 0) ? fmtDur(d) : 'сейчас';
			}

			statusCard.innerHTML = '';
			statusCard.appendChild(E('h3', {}, [ 'Задача' ]));
			statusCard.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ 'Состояние' ]),
				E('div', { 'class': 'cbi-value-field' }, [ String(s.state || '—') + ' / ' + String(job.phase || '—') ])
			]));
			statusCard.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ 'Активная цель' ]),
				E('div', { 'class': 'cbi-value-field' }, [
					(job.active_essid || '—') + ' (' + (job.active_bssid || '—') + ') ch ' + (job.channel || '—')
				])
			]));
			statusCard.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ 'Попытка / раунд' ]),
				E('div', { 'class': 'cbi-value-field' }, [ (job.attempt || 0) + ' / ' + (job.round || 1) ])
			]));
			statusCard.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ 'Захватов всего' ]),
				E('div', { 'class': 'cbi-value-field' }, [ String(cnt.caps_total || 0) + ' (попыток: ' + (cnt.attempts_total || 0) + ')' ])
			]));
			statusCard.appendChild(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ 'Следующий прогон' ]),
				E('div', { 'class': 'cbi-value-field' }, [ left ])
			]));

			if (s.last_error) {
				statusCard.appendChild(E('div', { 'class': 'alert-message danger' }, [
					String(s.last_error.code) + ': ' + String(s.last_error.msg)
				]));
			}

			statusCard.appendChild(E('div', { 'class': 'cbi-button-row' }, [
				btn('Старт', 'cbi-button-action', callJobStart),
				' ',
				btn('Пауза', 'cbi-button-neutral', callJobPause),
				' ',
				btn('Продолжить', 'cbi-button-neutral', callJobResume),
				' ',
				btn('Пропустить цель', 'cbi-button-neutral', callJobSkip),
				' ',
				btn('Очистить', 'cbi-button-reset', function() {
					if (!window.confirm('Остановить задачу и очистить очередь целей?\nЗахваченные файлы останутся.'))
						return;

					return callQueueClear().then(function(r) {
						notify((r && r.ok !== false) ? 'Очередь очищена' : 'Ошибка очистки', (r && r.ok !== false) ? 'info' : 'danger');
						return self.refreshAll();
					});
				})
			]));
		}

		function renderQueue(list) {
			list = list || [];
			queueTable.innerHTML = '';
			queueTable.appendChild(E('h3', {}, [ 'Очередь целей' ]));

			if (!list.length) {
				queueTable.appendChild(E('p', { 'class': 'cbi-value-description' }, [ 'Очередь пуста — добавьте цель из сканера' ]));
				return;
			}

			var rows = [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ 'BSSID' ]),
				E('th', { 'class': 'th' }, [ 'ESSID' ]),
				E('th', { 'class': 'th' }, [ 'CH' ]),
				E('th', { 'class': 'th' }, [ 'Состояние' ]),
				E('th', { 'class': 'th' }, [ 'CAP' ]),
				E('th', { 'class': 'th' }, [ 'Попытки' ]),
				E('th', { 'class': 'th' }, [ '' ])
			]) ];

			list.forEach(function(t) {
				var st = (t.section && status.queue) ? null : null;

				rows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [ t.bssid ]),
					E('td', { 'class': 'td' }, [ t.essid || '—' ]),
					E('td', { 'class': 'td' }, [ t.channel || '—' ]),
					E('td', { 'class': 'td' }, [ t.state || 'pending' ]),
					E('td', { 'class': 'td' }, [ String(t.caps || 0) ]),
					E('td', { 'class': 'td' }, [ String(t.attempts || 0) ]),
					E('td', { 'class': 'td' }, [
						E('a', { 'href': '#', 'click': ui.createHandlerFn(self, function(ev) {
							ev.preventDefault();
							return callTargetDelete(t.section).then(function() { return self.refreshAll(); });
						}) }, [ 'удалить' ])
					])
				]));
			});

			queueTable.appendChild(E('table', { 'class': 'table' }, rows));
		}

		var jobPane = E('div', {}, [ statusCard, queueTable,
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ 'Лог' ]), logBox ]) ]);

		/* ----------------------------------------------------- artifacts tab */

		var artTable = E('div', {}, []);

		function renderArtifacts(list) {
			list = list || [];
			artTable.innerHTML = '';

			if (!list.length) {
				artTable.appendChild(E('p', { 'class': 'cbi-value-description' }, [ 'Артефактов пока нет' ]));
				return;
			}

			var rows = [ E('tr', { 'class': 'tr table-titles' }, [
				E('th', { 'class': 'th' }, [ 'Файл' ]),
				E('th', { 'class': 'th' }, [ 'Размер' ]),
				E('th', { 'class': 'th' }, [ 'Дата' ]),
				E('th', { 'class': 'th' }, [ '' ])
			]) ];

			list.forEach(function(a) {
				var isHc = /\.22000$/.test(a.name);
				var kb = (a.size / 1024);
				var sizeStr = (kb >= 1024) ? (kb / 1024).toFixed(2) + ' МБ' : kb.toFixed(1) + ' КБ';

				rows.push(E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [ a.name ]),
					E('td', { 'class': 'td' }, [ sizeStr ]),
					E('td', { 'class': 'td' }, [ fmtTime(a.mtime) ]),
					E('td', { 'class': 'td' }, [
						isHc ? E('span', { 'class': 'cbi-value-description' }, [ 'для hashcat' ]) : E('a', { 'href': '#', 'click': ui.createHandlerFn(self, function(ev) {
							ev.preventDefault();
							// file.read with base64=true returns the binary payload
							// as base64 (plain fs.read() always reads text)
							return callFileReadB64(a.path, true).then(function(r) {
								if (!r || !r.data) {
									notify('Не удалось прочитать файл', 'danger');
									return;
								}

								var bin = atob(r.data);
								var arr = new Uint8Array(bin.length);

								for (var i = 0; i < bin.length; i++)
									arr[i] = bin.charCodeAt(i);

								var url = URL.createObjectURL(new Blob([ arr ], { type: 'application/octet-stream' }));
								var link = document.createElement('a');

								link.href = url;
								link.download = a.name;
								document.body.appendChild(link);
								link.click();
								document.body.removeChild(link);
								URL.revokeObjectURL(url);
							}).catch(function(e) {
								notify('Ошибка скачивания: ' + (e && e.message ? e.message : e), 'danger');
							});
						}) }, [ 'скачать' ]),
						' ',
						E('a', { 'href': '#', 'click': ui.createHandlerFn(self, function(ev) {
							ev.preventDefault();

							if (!window.confirm('Удалить файл с роутера?\n' + a.name))
								return;

							return callArtifactDelete(a.path).then(function(r) {
								notify((r && r.ok !== false) ? 'Файл удалён' : ('Ошибка: ' + ((r && r.error) || '?')), (r && r.ok !== false) ? 'info' : 'danger');
								return self.refreshAll();
							});
						}) }, [ 'удалить' ])
					])
				]));
			});

			artTable.appendChild(E('table', { 'class': 'table' }, rows));
		}

		var artPane = E('div', {}, [ E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ 'Артефакты' ]), artTable ]) ]);

		/* ------------------------------------------------------ settings tab */

		var inputs = {};
		var setRows = [];

		SETTINGS_FIELDS.forEach(function(f) {
			var inp = E('input', {
				'class': 'cbi-input-text',
				'type': f[2],
				'value': (settings[f[0]] != null) ? String(settings[f[0]]) : ''
			});

			inputs[f[0]] = inp;
			setRows.push(E('div', { 'class': 'cbi-value' }, [
				E('label', { 'class': 'cbi-value-title' }, [ f[1] ]),
				E('div', { 'class': 'cbi-value-field' }, [ inp ])
			]));
		});

		function saveSettings() {
			var val = {};

			Object.keys(inputs).forEach(function(k) { val[k] = inputs[k].value; });

			return callSettingsSet(JSON.stringify(val)).then(function(r) {
				if (!r || r.ok === false)
					notify('Ошибка сохранения: ' + ((r && r.error) || '?'), 'danger');
				else
					notify('Настройки сохранены (' + (r.changed || []).length + ')', 'info');
			});
		}

		var setPane = E('div', {}, [
			E('div', { 'class': 'cbi-section' },
				[ E('h3', {}, [ 'Параметры по умолчанию' ]) ]
					.concat(setRows)
					.concat([ E('div', { 'class': 'cbi-button-row' }, [
						btn('Сохранить', 'cbi-button-save', saveSettings)
					]) ]))
		]);

		/* --------------------------------------------------------------- shell */

		panes.push(scanPane, jobPane, artPane, setPane);

		var root = E('div', {}, [
			E('h2', {}, [ 'mrdark — захват EAPOL handshake' ]),
			E('div', { 'class': 'cbi-button-row' }, [
				makeTab('Сканер', 0), ' ', makeTab('Задача', 1), ' ', makeTab('Артефакты', 2), ' ', makeTab('Настройки', 3)
			]),
			E('div', { 'style': 'margin-top:1rem' }, panes)
		]);

		switchTab(0);

		renderNetworks(networks);
		renderStatus(status);
		renderQueue(targets);

		callArtifacts().then(function(r) { renderArtifacts((r || {}).artifacts || []); });
		if (status.scan && status.scan.state)
			scanInfo.appendChild(E('span', {}, [ 'Сканирование: ' + status.scan.state + ', сетей: ' + (status.scan.count || 0) ]));

		this.refreshAll = function() {
			return Promise.all([ callStatus(), callTargets(), callArtifacts(), callLogTail('200') ]).then(function(r) {
				status = r[0] || {};
				renderStatus(status);
				renderQueue((r[1] || {}).targets || []);
				renderArtifacts((r[2] || {}).artifacts || []);
				logBox.textContent = ((r[3] || {}).lines || []).join('\n');
			});
		};

		poll.add(function() {
			return callStatus().then(function(s) {
				status = s || {};
				renderStatus(status);
				if (activeTab === 1)
					return callLogTail('200').then(function(r) { logBox.textContent = ((r || {}).lines || []).join('\n'); });
			}).then(function() {
				return callTargets().then(function(r) {
					var list = (r || {}).targets || [];
					var q = (status.queue || []);
					var merged = list.map(function(t) {
						var m = q.filter(function(x) { return x.section === t.section; })[0] || {};
						return Object.assign({}, t, m);
					});
					renderQueue(merged);
				});
			});
		}, 2);

		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
