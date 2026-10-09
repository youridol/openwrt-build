'use strict';
'require view';
'require rpc';
'require ui';

// Telegram Bot 配置页。
//
// 【为什么单独一个视图（本仓库补丁，相对上游 1.21.4）】
//   上游把 Telegram 表单塞在「设备」页设置区的一个可折叠小节里。该表单极长
//   （实测单卡片 1270px：Token / Chat ID / 测试 / 模式切换 / 通知 / 自定义消息
//   + 变量表 + 内联键盘预览 + 机器人命令），与其它设置混在一起会把整页撑到
//   2600px 以上。现提升为**页面级独立 tab**，与「设备」「端口转发」并列，
//   由 menu.d 生成 —— 与上游 portfw 的做法一致，故不再需要页面内嵌套 tab。
//
// 样式复用 status.css（tg-* 与 tc-toggle* 均定义在那里）。
(function() {
	if (!document.querySelector('link[href*="trafficctl/status.css"]')) {
		var lnk = document.createElement('link');
		lnk.rel = 'stylesheet';
		lnk.type = 'text/css';
		lnk.href = '/luci-static/resources/view/trafficctl/status.css';
		document.head.appendChild(lnk);
	}
})();

var callTelegramGet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'telegram_config_get'
});

var callTelegramSet = rpc.declare({
	object: 'luci.trafficctl',
	method: 'telegram_config_set',
	params: ['enabled', 'bot_token', 'chat_id', 'poll_interval',
		'notify_new_device', 'notify_known_device', 'control_enabled', 'notify_template',
		'btn_block_inet', 'btn_block_wifi', 'btn_limiter', 'btn_shaper']
});

var callTelegramTest = rpc.declare({
	object: 'luci.trafficctl',
	method: 'telegram_test',
	params: ['bot_token', 'chat_id', 'message']
});

// 内联键盘预览用到的速率档位。只保留 Telegram 预览需要的那几项，
// 与「设备」页的 RATE_PRESETS 语义一致（此处不引用那边的作用域）。

var RATE_PRESETS = [
	{v:'0',      l: _('Off')},
	{v:'1000',   l:'1 Mbit/s'},
	{v:'2000',   l:'2 Mbit/s'},
	{v:'5000',   l:'5 Mbit/s'},
	{v:'10000',  l:'10 Mbit/s'},
	{v:'25000',  l:'25 Mbit/s'},
	{v:'50000',  l:'50 Mbit/s'},
	{v:'100000', l:'100 Mbit/s'},
	{v:'custom', l: _('Custom…')}
];

function mkToggle(id, label, checked, onChange) {
	var cb = E('input', { 'type': 'checkbox', 'id': id, 'class': 'tc-toggle-input' });
	cb.checked = !!checked;
	cb.addEventListener('change', onChange);
	var track = E('label', { 'class': 'tc-toggle', 'for': id });
	return E('div', { 'class': 'tc-toggle-wrap' }, [
		cb, track,
		E('label', { 'for': id, 'style': 'cursor:pointer;font-size:12px;user-select:none;color:currentColor' }, label)
	]);
}

function loadTelegramUI(container) {
	var statusSpan = E('span', {'style':'font-size:12px;margin-left:8px;color:var(--tc-muted)'}, _('Loading…'));
	container.appendChild(statusSpan);

	callTelegramGet().then(function(cfg) {
		while (container.firstChild) container.removeChild(container.firstChild);

		var section = E('div', {'class':'tg-section'});
		container.appendChild(section);

		// ── Auto-save with debounce ──
		var saveTimer = null;
		var setupDone = false;
		var saveStatus = E('span', {'class':'tg-save-status'});
		var doSave = function() {
			if (!setupDone) return;
			if (saveTimer) clearTimeout(saveTimer);
			saveTimer = setTimeout(function() {
				saveStatus.textContent = _('Saving…');
				saveStatus.style.color = 'var(--tc-muted)';
				var tk = tokenInput.value;
				if (tk === '' && cfg.bot_token_set) tk = '***';
				var inetEl = container.querySelector('#tm-tg-inet');
				var wifiEl = container.querySelector('#tm-tg-wifi');
				var limitEl = container.querySelector('#tm-tg-limit');
				var shapeEl = container.querySelector('#tm-tg-shape');
				callTelegramSet(
					container.querySelector('#tm-tg-enabled').checked,
					tk,
					chatInput.value,
					parseInt(cfg.poll_interval) || 3,
					container.querySelector('#tm-tg-new').checked,
					container.querySelector('#tm-tg-known').checked,
					controlMode,
					templateArea.value,
					inetEl ? inetEl.checked : cfg.btn_block_inet,
					wifiEl ? wifiEl.checked : cfg.btn_block_wifi,
					limitEl ? limitEl.checked : cfg.btn_limiter,
					shapeEl ? shapeEl.checked : cfg.btn_shaper
				).then(function(res) {
					if (res && res.ok) {
						saveStatus.textContent = '✓';
						saveStatus.style.color = 'var(--tc-ok)';
						cfg.bot_token_set = !!(tk && tk !== '***') || cfg.bot_token_set;
						if (tk && tk !== '***') {
							tokenInput.value = '';
							tokenInput.type = 'password';
							tokenInput.placeholder = '••••••••  ✓ ' + _('saved');
						}
					} else {
						saveStatus.textContent = '✗ ' + (res && res.msg || 'error');
						saveStatus.style.color = 'var(--tc-err)';
					}
				}).catch(function(e) {
					saveStatus.textContent = '✗ ' + e.message;
					saveStatus.style.color = 'var(--tc-err)';
				});
			}, 600);
		};

		// ── Status dot ──
		var dot = E('span', {
			'class': 'tg-status-dot ' + (cfg.bot_running ? 'tg-status-dot--on' : 'tg-status-dot--off'),
			'title': cfg.bot_running ? _('Bot is running') : _('Bot is stopped')
		});

		// ── Enabled toggle ──
		var tgEnabled = mkToggle('tm-tg-enabled', _('Enabled'), cfg.enabled, doSave);
		section.appendChild(E('div', {'class':'tg-row'}, [tgEnabled, dot, saveStatus]));

		// ── Token + Chat ID ──
		var tokenInput = E('input', {
			'type': 'password',
			'class': 'tg-input tg-input--token',
			'value': '',
			'placeholder': cfg.bot_token_set ? '••••••••  ✓ ' + _('saved') : _('Paste bot token')
		});
		tokenInput.addEventListener('change', doSave);
		var eyeBtn = E('span', {'class':'tg-eye','title':_('Show/hide token')}, '👁');
		eyeBtn.addEventListener('click', function() {
			tokenInput.type = tokenInput.type === 'password' ? 'text' : 'password';
		});
		var chatInput = E('input', {
			'type': 'text',
			'class': 'tg-input tg-input--chat',
			'value': cfg.chat_id || '',
			'placeholder': _('Chat ID')
		});
		chatInput.addEventListener('change', doSave);
		var testResult = E('span', {'style':'font-size:11px;margin-left:4px'});
		var testBtn = E('button', {'class':'tg-btn'}, _('Test'));
		testBtn.addEventListener('click', function() {
			testBtn.disabled = true;
			testResult.textContent = _('Sending…');
			testResult.style.color = 'var(--tc-muted)';
			var tk = tokenInput.value || '***';
			callTelegramTest(tk, chatInput.value, templateArea.value || '').then(function(res) {
				testResult.textContent = (res && res.ok) ? '✓ ' + (res.msg || 'OK') : '✗ ' + (res && res.msg || 'error');
				testResult.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
			}).catch(function(e) {
				testResult.textContent = '✗ ' + e.message;
				testResult.style.color = 'var(--tc-err)';
			}).then(function() { testBtn.disabled = false; });
		});
		section.appendChild(E('div', {'class':'tg-row'}, [
			E('span', {'class':'tg-label'}, _('Token:')), tokenInput, eyeBtn,
			E('span', {'style':'width:12px'}),
			E('span', {'class':'tg-label'}, _('Chat ID:')), chatInput,
			testBtn, testResult
		]));

		// ── Mode segmented control ──
		var controlMode = cfg.control_enabled !== false;
		var controlSection = E('div', {});
		var notifySection = E('div', {});
		function setMode(ctrl) {
			controlMode = ctrl;
			segControl.className = 'tg-segmented__item' + (ctrl ? ' tg-segmented__item--active' : '');
			segNotify.className = 'tg-segmented__item' + (!ctrl ? ' tg-segmented__item--active' : '');
			controlSection.classList.toggle('tc-hidden', !ctrl);
			doSave();
		}

		var segNotify = document.createElement('div');
		segNotify.className = 'tg-segmented__item' + (!controlMode ? ' tg-segmented__item--active' : '');
		segNotify.textContent = '🔔 ' + _('Notifications only');
		segNotify.onclick = function() { setMode(false); };

		var segControl = document.createElement('div');
		segControl.className = 'tg-segmented__item' + (controlMode ? ' tg-segmented__item--active' : '');
		segControl.textContent = '🎛 ' + _('Full control');
		segControl.onclick = function() { setMode(true); };

		var segmented = E('div', {'class':'tg-segmented'}, [segNotify, segControl]);

		section.appendChild(E('div', {'class':'tg-row'}, [segmented]));

		// ── Notifications ──
		notifySection.appendChild(E('div', {'class':'tg-divider'}, _('Notifications')));
		var notifyNew = mkToggle('tm-tg-new', _('New devices'), cfg.notify_new_device, doSave);
		var notifyKnown = mkToggle('tm-tg-known', _('Known devices'), cfg.notify_known_device, doSave);
		notifySection.appendChild(E('div', {'class':'tg-row'}, [notifyNew, notifyKnown]));

		// ── Custom template ──
		var templateArea = E('textarea', {
			'class': 'tg-input tg-input--template',
			'placeholder': '🆕 New device\\n{{ name }} ({{ ip }})\\nMAC: {{ mac }}\\nLink: {{ link }}'
		}, cfg.notify_template || '');
		templateArea.addEventListener('input', function() { renderPreview(); doSave(); });

		var previewBubble = E('div', {'class':'tg-bubble'});
		var defaultTpl = '🆕 <b>New device</b>\n{{ name }} ({{ ip }})\nMAC: <code>{{ mac }}</code>\nLink: {{ link }}';
		var renderPreview = function() {
			var tpl = templateArea.value || defaultTpl;
			var txt = tpl
				.replace(/\{\{\s*name\s*\}\}/g, 'MacBookPro')
				.replace(/\{\{\s*ip\s*\}\}/g, '192.168.0.100')
				.replace(/\{\{\s*mac\s*\}\}/g, 'aa:bb:cc:dd:ee:ff')
				.replace(/\{\{\s*link\s*\}\}/g, '5G')
				.replace(/\{\{\s*date\s*\}\}/g, new Date().toISOString().slice(0,10))
				.replace(/\{\{\s*time\s*\}\}/g, new Date().toTimeString().slice(0,5))
				.replace(/\{\{\s*datetime\s*\}\}/g, new Date().toISOString().slice(0,10) + ' ' + new Date().toTimeString().slice(0,5))
				.replace(/\{\{\s*router\s*\}\}/g, 'OpenWrt')
				.replace(/\{\{\s*ssid\s*\}\}/g, 'MyNetwork_5G')
				.replace(/\{\{\s*signal\s*\}\}/g, '-52')
				.replace(/\{\{\s*freq\s*\}\}/g, '5GHz')
				.replace(/\{\{\s*iface\s*\}\}/g, 'wlan1')
				.replace(/\{\{\s*clients\s*\}\}/g, '12')
				.replace(/\{\{\s*uptime\s*\}\}/g, '3d 5h')
				.replace(/\{\{\s*wan_ip\s*\}\}/g, '85.192.48.1')
				.replace(/\{\{\s*load\s*\}\}/g, '0.42')
				.replace(/\{\{\s*conns\s*\}\}/g, '47');
			previewBubble.innerHTML = txt.replace(/\\n/g, '<br>').replace(/\n/g, '<br>');
		};
		renderPreview();

		var varRef = E('div', {'style':'font-size:12px;line-height:1.7;color:currentColor'}, [
			E('div', {'style':'font-weight:600;margin-bottom:4px'}, _('Variables')),
			E('div', {}, [E('code', {}, '{{ name }}'), document.createTextNode(' — ' + _('device hostname'))]),
			E('div', {}, [E('code', {}, '{{ ip }}'), document.createTextNode(' — ' + _('IP address'))]),
			E('div', {}, [E('code', {}, '{{ mac }}'), document.createTextNode(' — ' + _('MAC address'))]),
			E('div', {}, [E('code', {}, '{{ link }}'), document.createTextNode(' — ' + _('connection type (5G, LAN)'))]),
			E('div', {}, [E('code', {}, '{{ date }}'), document.createTextNode(' — ' + _('date (2026-05-26)'))]),
			E('div', {}, [E('code', {}, '{{ time }}'), document.createTextNode(' — ' + _('time (14:32)'))]),
			E('div', {}, [E('code', {}, '{{ datetime }}'), document.createTextNode(' — ' + _('date + time'))]),
			E('div', {}, [E('code', {}, '{{ router }}'), document.createTextNode(' — ' + _('router hostname'))]),
			E('div', {}, [E('code', {}, '{{ ssid }}'), document.createTextNode(' — ' + _('WiFi SSID'))]),
			E('div', {}, [E('code', {}, '{{ signal }}'), document.createTextNode(' — ' + _('WiFi signal (dBm)'))]),
			E('div', {}, [E('code', {}, '{{ freq }}'), document.createTextNode(' — ' + _('WiFi band (2.4/5GHz)'))]),
			E('div', {}, [E('code', {}, '{{ iface }}'), document.createTextNode(' — ' + _('network interface'))]),
			E('div', {}, [E('code', {}, '{{ clients }}'), document.createTextNode(' — ' + _('total connected clients'))]),
			E('div', {}, [E('code', {}, '{{ uptime }}'), document.createTextNode(' — ' + _('router uptime'))]),
			E('div', {}, [E('code', {}, '{{ wan_ip }}'), document.createTextNode(' — ' + _('WAN IP'))]),
			E('div', {}, [E('code', {}, '{{ load }}'), document.createTextNode(' — ' + _('CPU load (1 min)'))]),
			E('div', {}, [E('code', {}, '{{ conns }}'), document.createTextNode(' — ' + _('device connections'))]),
			E('div', {'style':'margin-top:6px;color:var(--tc-muted);font-size:11px'}, [
				document.createTextNode(_('HTML:') + ' '),
				E('code', {}, '<b>'), document.createTextNode(' '),
				E('code', {}, '<i>'), document.createTextNode(' '),
				E('code', {}, '<code>'), document.createTextNode(' '),
				E('code', {}, '<a href="">'),
				document.createTextNode('. \\n = ' + _('line break'))
			])
		]);

		var templateToggle = E('span', {
			'style': 'font-size:12px;cursor:pointer;color:var(--tc-muted);user-select:none'
		}, '▸ ' + _('Customize message'));
		var templateBody = E('div', {'class':'tc-hidden','style':'margin-top:6px'});
		templateBody.appendChild(E('div', {'style':'display:flex;gap:14px;align-items:flex-start;flex-wrap:wrap'}, [
			E('div', {'style':'flex:1;min-width:200px'}, [templateArea]),
			varRef
		]));
		templateBody.appendChild(E('div', {'style':'margin-top:8px'}, [
			E('span', {'class':'tg-label','style':'display:block;margin-bottom:4px'}, _('Preview:')),
			previewBubble
		]));
		templateToggle.addEventListener('click', function() {
			var show = templateBody.classList.contains('tc-hidden');
			templateBody.classList.toggle('tc-hidden');
			templateToggle.textContent = (show ? '▾ ' : '▸ ') + _('Customize message');
		});
		notifySection.appendChild(E('div', {'style':'margin-top:8px'}, [templateToggle, templateBody]));

		// ── Control section (conditionally visible) ──
		controlSection.appendChild(E('div', {'class':'tg-divider'}, _('Control')));
		var btnInet = mkToggle('tm-tg-inet', _('Block Internet'), cfg.btn_block_inet, function() { updateKbd(); doSave(); });
		var btnWifi = mkToggle('tm-tg-wifi', _('Block WiFi'), cfg.btn_block_wifi, function() { updateKbd(); doSave(); });
		var btnLimit = mkToggle('tm-tg-limit', _('Limiter'), cfg.btn_limiter, function() { updateKbd(); doSave(); });
		var btnShape = mkToggle('tm-tg-shape', _('Shaper'), cfg.btn_shaper, function() { updateKbd(); doSave(); });
		controlSection.appendChild(E('div', {'class':'tg-row'}, [btnInet, btnWifi, btnLimit, btnShape]));

		// Dynamic keyboard preview
		var kbdBubble = E('div', {'class':'tg-bubble tg-bubble--kbd'});
		var updateKbd = function() {
			while (kbdBubble.firstChild) kbdBubble.removeChild(kbdBubble.firstChild);
			var inetEl = controlSection.querySelector('#tm-tg-inet');
			var wifiEl = controlSection.querySelector('#tm-tg-wifi');
			var limitEl = controlSection.querySelector('#tm-tg-limit');
			var shapeEl = controlSection.querySelector('#tm-tg-shape');
			var inetOn = inetEl ? inetEl.checked : cfg.btn_block_inet;
			var wifiOn = wifiEl ? wifiEl.checked : cfg.btn_block_wifi;
			var limitOn = limitEl ? limitEl.checked : cfg.btn_limiter;
			var shapeOn = shapeEl ? shapeEl.checked : cfg.btn_shaper;
			if (!inetOn && !wifiOn && !limitOn && !shapeOn) {
				kbdBubble.appendChild(E('div', {'style':'font-size:11px;color:var(--tc-faint);padding:4px'}, _('No action buttons enabled')));
				return;
			}
			var row1 = [];
			if (inetOn) row1.push(E('span', {'class':'tg-kbd-btn'}, '⏸ Block Internet'));
			if (wifiOn) row1.push(E('span', {'class':'tg-kbd-btn'}, '📵 Block WiFi'));
			if (row1.length) kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, row1));
			if (limitOn) {
				var limitBtns = [];
				RATE_PRESETS.forEach(function(p) {
					if (p.v === '0' || p.v === 'custom') return;
					limitBtns.push(E('span', {'class':'tg-kbd-btn'}, p.l.replace(' Mbit/s', 'M').replace(/\s/g, '')));
				});
				for (var li = 0; li < limitBtns.length; li += 3) {
					kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, limitBtns.slice(li, li + 3)));
				}
			}
			if (shapeOn) {
				var shapeBtns = [];
				RATE_PRESETS.forEach(function(p) {
					if (p.v === '0' || p.v === 'custom') return;
					shapeBtns.push(E('span', {'class':'tg-kbd-btn'}, '🔧 ' + p.l.replace(' Mbit/s', 'M').replace(/\s/g, '')));
				});
				for (var si = 0; si < shapeBtns.length; si += 3) {
					kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, shapeBtns.slice(si, si + 3)));
				}
			}
			kbdBubble.appendChild(E('div', {'class':'tg-kbd-row'}, [
				E('span', {'class':'tg-kbd-btn'}, '⬅️ Back')
			]));
		};
		updateKbd();

		controlSection.appendChild(E('div', {'style':'margin-top:8px'}, [
			E('span', {'class':'tg-label','style':'display:block;margin-bottom:4px'}, _('Inline keyboard preview:')),
			kbdBubble
		]));

		// Commands + flow explanation
		controlSection.appendChild(E('div', {'style':'margin-top:10px'}, [
			E('span', {'class':'tg-label','style':'display:block;margin-bottom:4px'}, _('Bot commands:')),
			E('div', {'class':'tg-commands'}, [
				E('div', {}, [E('code', {}, '/devices'), document.createTextNode(' — ' + _('device list → tap device → action buttons'))]),
				E('div', {}, [E('code', {}, '/status'), document.createTextNode(' — ' + _('all active blocks, limits, and shapes'))]),
				E('div', {}, [E('code', {}, '/help'), document.createTextNode(' — ' + _('command list and bot mode'))])
			]),
			E('div', {'style':'font-size:10px;color:var(--tc-faint);margin-top:4px'},
				_('Flow: /devices → select device → inline keyboard with enabled actions above'))
		]));

		if (!controlMode) controlSection.classList.add('tc-hidden');
		section.appendChild(controlSection);
		section.appendChild(notifySection);
		setupDone = true;
	}).catch(function(e) {
		statusSpan.textContent = '✗ ' + e.message;
		statusSpan.style.color = 'var(--tc-err)';
	});
}


return view.extend({
	load: function() {
		return Promise.resolve();
	},

	render: function() {
		var container = E('div', {'class': 'tg-page'});
		loadTelegramUI(container);

		return E('div', {'class': 'cbi-map', 'style': 'color:currentColor'}, [
			E('h2', {'style': 'color:currentColor'}, _('Telegram Bot')),
			E('div', {'class': 'cbi-map-descr'}, _('Notifications and remote control over Telegram. Changes are saved automatically.')),
			container
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
