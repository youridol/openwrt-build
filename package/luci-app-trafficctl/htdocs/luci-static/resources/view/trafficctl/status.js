'use strict';
'require view';
'require rpc';
'require fs';
'require ui';
// 【本仓库改动】rpc 声明、选项存取、格式化与几个小控件统一移到
// trafficctl/common.js：设置页（settings.js）也要用同一套，若各自复制一份，
// 同一个开关在不同页面的行为会渐渐不一致。
// 下面用别名把本文件里原有的调用点全部接过去，故正文一行不需要改动。
'require trafficctl/common as T';

(function() {
	if (!document.querySelector('link[href*="trafficctl/status.css"]')) {
		var lnk = document.createElement('link');
		lnk.rel = 'stylesheet';
		lnk.type = 'text/css';
		lnk.href = '/luci-static/resources/view/trafficctl/status.css';
		document.head.appendChild(lnk);
	}
})();

var TRAFFICCTL_BUILD = '20260928a';
console.log('[trafficctl] build:' + TRAFFICCTL_BUILD);

// Per-device DPI app breakdown from netifyd, keyed by IP. Stays empty when the
// agent isn't running, which is what makes the App column degrade quietly.
var netifyMap = {};

// 【本仓库改动】以下这些此前定义在本文件里，现已移入 trafficctl/common.js
// （设置页要用同一份）。这里保留同名别名，正文的调用点因此一行都不用改。
var STORAGE_KEY = T.STORAGE_KEY;
var RECENT_KEY = T.RECENT_KEY;
var MAX_RECENT = T.MAX_RECENT;
var FULL_HISTORY_MAX = 1800;
// Per-interface history for the overview graph. Deliberately far smaller than
// FULL_HISTORY_MAX: this is kept for EVERY interface at once (a router with a
// few tunnels easily has a dozen), where _fullHistory only ever holds the one
// device the user opened. 600 samples is 20 min at the default 2 s poll.
var IFACE_HISTORY_MAX = 600;
// How many devices the "Top talkers" list shows. The point of the list is to
// answer "who is using the line right now" at a glance; a longer list is what
// the per-device table below already is.
var TOP_TALKERS = 5;
var _fgGraphIdSeq = 0;

var getRecentDevices    = T.getRecentDevices;
var saveRecentDevices   = T.saveRecentDevices;
var addRecentDevice     = T.addRecentDevice;

var SERVICE_PORTS = {
	20:'ftp-data', 21:'ftp', 22:'ssh', 23:'telnet', 25:'smtp',
	53:'dns', 80:'http', 110:'pop3', 143:'imap', 179:'bgp',
	443:'https', 465:'smtps', 587:'smtp', 853:'dns-tls',
	993:'imaps', 995:'pop3s', 1194:'openvpn', 3478:'stun',
	5222:'xmpp', 5228:'gcm', 8080:'http-alt', 8443:'https-alt',
	19302:'stun', 51820:'wireguard'
};

// 【本仓库改动】以下 rpc 声明已移入 trafficctl/common.js（设置页共用同一份）。
// 用别名接回原名字，正文所有调用点保持不变。
var callTrafficctl        = T.trafficctl;
var callDevice            = T.device;
var callBytes             = T.bytes;
var callIfaces            = T.ifaces;
var callBlock             = T.block;
var callUnblock           = T.unblock;
var callMacfilterAdd      = T.macfilterAdd;
var callMacfilterRemove   = T.macfilterRemove;
var callRatelimit         = T.ratelimit;
var callRatelimitStats    = T.ratelimitStats;
var callSubnets           = T.subnets;
var callShapeAdd          = T.shapeAdd;
var callShapeRemove       = T.shapeRemove;
var callShapeStats        = T.shapeStats;
var callNetifyList        = T.netifyList;
var callNameSet           = T.nameSet;
var callLoggingGet        = T.loggingGet;
var callLoggingSet        = T.loggingSet;
var callNewDeviceGet      = T.newDeviceGet;
var callNewDeviceSet      = T.newDeviceSet;
// Global internet cut. cut_status 是写方法：它会同时对自动回滚的截止时间做一次
// 核对，并唤醒已停摆的 keeper，故它给出的「当前 nft 规则是否真的在」才可信。
var callCutStatus         = T.cutStatus;
var callCutSet            = T.cutSet;
var callActivityLog       = T.activityLog;
var callVersion           = T.version;
var callConfigSet         = T.configSet;
var callNetworkRrdnsLookup = T.networkRrdnsLookup;
var callConfigGet         = T.configGet;

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

var GROUP_OPTS = [
	{v:'none',    l: _('None (per-flow)')},
	{v:'host',    l: _('Hostname / Dst IP')},
	{v:'service', l: _('Service')},
	{v:'port',    l: _('Port')},
	{v:'proto',   l: _('Protocol')}
];

// 【本仓库改动】选项存取与纯格式化函数已移入 trafficctl/common.js
// （设置页要用同一份，否则同一档位在两页的默认值会不一致）。
// 用别名接回原名字，正文调用点不变。
var siteDefaults = T.siteDefaults;
var loadOpts     = T.loadOpts;
var saveOpts     = T.saveOpts;
var optPoll      = T.optPoll;
var optWindow    = T.optWindow;
var optRefresh   = T.optRefresh;
var fmtBytes     = T.fmtBytes;
var fmtSpeed     = T.fmtSpeed;
var fmtRate      = T.fmtRate;
var escHtml      = T.escHtml;
// The Bytes / TCP / UDP columns show a LIFETIME total accumulated on the
// router by trafficctl-totals.sh, not the live conntrack sums they used to
// show. conntrack only accounts for flows that still exist, so the old numbers
// collapsed to absurdities like "2 bytes" the moment a device went briefly
// idle — that is issue #26.
//
// A negative total means the router cannot answer, which is not the same as
// zero: under flow offload the byte source becomes nftables counter maps keyed
// by address alone, which cannot split TCP from UDP. Printing 0 there would be
// a confident wrong answer, i.e. the very failure this change removes.
function renderTotalCell(cell, total, liveVal, since, pending, degraded) {
	while (cell.firstChild) {
		cell.removeChild(cell.firstChild);
	}
	if (pending) {
		cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '…'));
		cell.title = _('Waiting for the first byte sample.');
		return;
	}
	// The router told us these counters are frozen for offloaded flows, so the
	// total is a lower bound that stalls while traffic continues. Refused
	// rather than shown: a plausible number that quietly stops growing reads as
	// stale statistics, not as a broken counter, and is far harder to notice
	// than the implausibly small live values that prompted issue #26.
	if (degraded) {
		cell.appendChild(E('span', { 'class': 'tc-c-err tc-fw-bold' }, '⚠'));
		cell.title = _('Not counted: flow offload is active and this router cannot provide the nftables counters trafficctl uses in that mode, so the kernel byte counters stop updating for offloaded connections. Any total here would be far too low. See Settings → Flow Offload.');
		return;
	}
	if (total == null || total < 0) {
		cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '—'));
		cell.title = _('Not measurable while flow offload is active: in that mode the router counts bytes per address only, so traffic cannot be split by protocol. See Settings → Flow Offload.');
		return;
	}
	cell.appendChild(document.createTextNode(fmtBytes(total)));
	var tip = since
		? (_('Accumulated since') + ' ' + new Date(since * 1000).toLocaleString())
		: _('Accumulated on the router');
	tip += '\n' + _('Resets when the router reboots.');
	if (liveVal != null && liveVal >= 0) {
		tip += '\n' + _('Currently tracked connections hold') + ' ' + fmtBytes(liveVal);
	}
	cell.title = tip;
}

// Render a "↓ down / ↑ up" speed cell. Both halves come from the same
// bytes_in/bytes_out sample, so they are always consistent with each other.
function renderSpeedCell(cell, sd) {
	while (cell.firstChild) cell.removeChild(cell.firstChild);
	if (!sd) {
		cell.className = 'td tc-right tc-mono tc-speed-idle';
		cell.appendChild(document.createTextNode('—'));
		return;
	}
	// Download only — upload has its own sortable "UL Speed" column, so showing
	// it here too would duplicate it and make neither column sortable on its own.
	cell.className = 'td tc-right tc-mono ' + (sd.current > 1024 ? 'tc-speed-active' : 'tc-speed-idle');
	cell.appendChild(document.createTextNode(fmtSpeed(sd.current)));
}

// 主机实时连接详情页的地址。该路由（admin/status/trafficctl/host/<ip>）在
// menu.d 里刻意**不设 title**：可直达、可收藏、可后退，但不会在侧边栏多出
// 一个永远点不开的菜单项。
function hostDetailUrl(ip) {
	return L.url('admin/status/trafficctl/host') + '/' + encodeURIComponent(ip);
}

// Manual device naming. Routed devices (behind a downstream router) have no
// DHCP lease on this router, so an alias — or a PTR record the backend
// resolves — is the only way they get a name instead of "*".
function promptRename(ip, current, onDone) {
	var input = E('input', {
		'type': 'text',
		'class': 'cbi-input-text',
		'value': current === '*' ? '' : current,
		'placeholder': _('Device name'),
		'style': 'width:100%'
	});

	var doSave = function() {
		var v = (input.value || '').replace(/[^a-zA-Z0-9 _.()-]/g, '').substring(0, 32);
		callNameSet(ip, v).then(function(res) {
			ui.hideModal();
			if (res && res.ok === false) {
				ui.addNotification(null, E('p', res.msg || _('Rename failed')), 'error');
				return;
			}
			if (onDone) onDone(v);
		}).catch(function(e) {
			ui.hideModal();
			ui.addNotification(null, E('p', e.message), 'error');
		});
	};

	input.addEventListener('keydown', function(ev) {
		if (ev.key === 'Enter') { ev.preventDefault(); doSave(); }
	});

	var cancelBtn = E('button', { 'class': 'btn' }, _('Cancel'));
	cancelBtn.addEventListener('click', function() { ui.hideModal(); });
	var saveBtn = E('button', { 'class': 'btn cbi-button-positive' }, _('Save'));
	saveBtn.addEventListener('click', doSave);

	ui.showModal(_('Rename device') + ' — ' + ip, [
		E('p', { 'class': 'tc-c-muted', 'style': 'font-size:12px' },
			_('Overrides the DHCP lease or DNS name. Leave empty to clear the custom name.')),
		E('div', { 'style': 'margin:10px 0' }, input),
		E('div', { 'class': 'right' }, [cancelBtn, ' ', saveBtn])
	]);
	setTimeout(function() { input.focus(); input.select(); }, 50);
}

function mkEthIcon(size) {
	var s = size || 14;
	var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	svg.setAttribute('width', s);
	svg.setAttribute('height', s);
	svg.setAttribute('viewBox', '0 0 24 24');
	svg.setAttribute('fill', 'none');
	svg.setAttribute('stroke', 'currentColor');
	svg.setAttribute('stroke-width', '2');
	svg.setAttribute('stroke-linecap', 'round');
	svg.setAttribute('stroke-linejoin', 'round');
	svg.setAttribute('class', 'tc-eth-icon');
	var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
	path.setAttribute('d', 'M4 7h16a1 1 0 0 1 1 1v8a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM7 11v2M10 11v2M13 11v2M16 11v2');
	svg.appendChild(path);
	return svg;
}

// Marks a device that the WiFi MAC filter lists as blocked. `pending` is the
// backend's wifi_block_pending: the device is on the deny list AND associated
// on a radio right now, which is proof the running hostapd ACL never got the
// block. Saying "blocked" there is the lie this whole change exists to remove,
// so that case gets its own wording and colour.
function mkWifiBlockBadge(pending) {
	return E('span', {
		'class': pending ? 'tc-c-err tc-fw-bold' : 'tc-c-warn tc-fw-bold',
		'style': 'margin-left:4px;cursor:help;white-space:nowrap',
		'title': pending
			? _('On the WiFi deny list but still connected — the block is NOT in effect on the running radio. Install hostapd-utils so blocks apply immediately, or restart WiFi (disconnects every client).')
			: _('Blocked from WiFi (MAC deny list)')
	}, pending ? '📵⚠' : '📵');
}

function renderSparkline(history, globalMax, width, height, limitKbit) {
	if (!history || history.length < 2) return null;
	var maxVal = globalMax || 1;
	var w = width || 60;
	var h = height || 20;
	var step = w / (history.length - 1);
	var points = [];
	for (var i = 0; i < history.length; i++) {
		var x = (i * step).toFixed(1);
		var y = (h - (history[i].speed / maxVal) * (h - 2) - 1).toFixed(1);
		points.push(x + ',' + y);
	}
	var svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
	svg.setAttribute('width', w);
	svg.setAttribute('height', h);
	svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
	svg.style.cssText = 'display:block;margin:0 auto'; /* sparkline — kept inline (runtime/canvas) */
	var area = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
	area.setAttribute('points', '0,' + h + ' ' + points.join(' ') + ' ' + (w - 0) + ',' + h);
	area.setAttribute('fill', 'var(--tc-speed)');
	area.setAttribute('opacity', '0.1');
	area.setAttribute('stroke', 'none');
	svg.appendChild(area);
	// Rate limit line (dashed, red/orange)
	if (limitKbit && limitKbit > 0) {
		var limitBps = limitKbit * 1000 / 8;
		if (limitBps < maxVal) {
			var ly = (h - (limitBps / maxVal) * (h - 2) - 1).toFixed(1);
			var line = document.createElementNS('http://www.w3.org/2000/svg', 'line');
			line.setAttribute('x1', '0'); line.setAttribute('x2', String(w));
			line.setAttribute('y1', ly); line.setAttribute('y2', ly);
			line.setAttribute('stroke', 'var(--tc-warn)');
			line.setAttribute('stroke-width', '1');
			line.setAttribute('stroke-dasharray', '3,2');
			line.setAttribute('opacity', '0.7');
			svg.appendChild(line);
		}
	}
	var polyline = document.createElementNS('http://www.w3.org/2000/svg', 'polyline');
	polyline.setAttribute('points', points.join(' '));
	polyline.setAttribute('fill', 'none');
	polyline.setAttribute('stroke', 'var(--tc-speed)');
	polyline.setAttribute('stroke-width', '1.5');
	polyline.setAttribute('stroke-linejoin', 'round');
	svg.appendChild(polyline);
	return svg;
}

function renderFullGraph(history, limitKbit, width, height) {
	if (!history || history.length < 2) return null;
	var w = width || 440, h = height || 200;
	var pad = {top:22, right:14, bottom:32, left:56};
	var gw = w - pad.left - pad.right, gh = h - pad.top - pad.bottom;
	var gradIdSuffix = '-' + (++_fgGraphIdSeq);
	var ns = 'http://www.w3.org/2000/svg';

	var maxSpeed = 0, maxUp = 0;
	var hasUpload = history.some(function(p) { return p.up > 0; });
	// Use 98th percentile to ignore spikes
	var speeds = history.map(function(p) { return p.speed; }).sort(function(a,b){return a-b;});
	var p98idx = Math.min(speeds.length - 1, Math.floor(speeds.length * 0.98));
	maxSpeed = speeds[p98idx] || 0;
	// But ensure absolute max is at most 3x the p98 (clip extreme outliers visually)
	var absMax = speeds[speeds.length - 1];
	if (absMax > maxSpeed * 3) maxSpeed = maxSpeed * 1.5;
	else maxSpeed = absMax;
	history.forEach(function(p) { if (p.up > maxUp) maxUp = p.up; });
	var limitBps = limitKbit ? (limitKbit * 1000 / 8) : 0;
	if (limitBps > maxSpeed) maxSpeed = limitBps * 1.1;
	if (maxUp > maxSpeed) maxSpeed = maxUp;
	if (maxSpeed < 1) maxSpeed = 1;
	// Round maxSpeed up to a nice tick boundary (multiples of 100 or 500 kbit/s in bytes/s)
	var niceSteps = [100/8*1000, 200/8*1000, 500/8*1000, 1000/8*1000, 2000/8*1000, 5000/8*1000,
		10000/8*1000, 20000/8*1000, 50000/8*1000, 100000/8*1000, 200000/8*1000, 500000/8*1000, 1000000/8*1000];
	var tickStep = niceSteps[0];
	for (var ns_i = 0; ns_i < niceSteps.length; ns_i++) {
		if (maxSpeed / niceSteps[ns_i] <= 8) { tickStep = niceSteps[ns_i]; break; }
	}
	var gridCount = Math.max(5, Math.ceil(maxSpeed / tickStep));
	maxSpeed = gridCount * tickStep;

	var startTime = history[0].time;
	var endTime = history[history.length - 1].time;
	var duration = endTime - startTime || 1;

	function xScale(t) { return pad.left + ((t - startTime) / duration) * gw; }
	function yScale(v) { return pad.top + gh - (v / maxSpeed) * gh; }

	// Compute min/max bands (rolling window of 5 points)
	var bandData = [];
	var bandWin = Math.max(2, Math.min(5, Math.floor(history.length / 8)));
	for (var bi = 0; bi < history.length; bi++) {
		var lo = Infinity, hi = 0;
		for (var bj = Math.max(0, bi - bandWin); bj <= Math.min(history.length - 1, bi + bandWin); bj++) {
			if (history[bj].speed < lo) lo = history[bj].speed;
			if (history[bj].speed > hi) hi = history[bj].speed;
		}
		bandData.push({time: history[bi].time, lo: lo, hi: hi});
	}

	var svg = document.createElementNS(ns, 'svg');
	svg.setAttribute('width', w); svg.setAttribute('height', h);
	svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
	svg.style.cssText = 'display:block;border-radius:8px;overflow:visible';

	// Gradient definition for download area
	var defs = document.createElementNS(ns, 'defs');
	var grad = document.createElementNS(ns, 'linearGradient');
	grad.setAttribute('id', 'fg-dl-grad'+gradIdSuffix); grad.setAttribute('x1', '0'); grad.setAttribute('y1', '0');
	grad.setAttribute('x2', '0'); grad.setAttribute('y2', '1');
	var stop1 = document.createElementNS(ns, 'stop');
	stop1.setAttribute('offset', '0%'); stop1.setAttribute('stop-color', 'var(--tc-speed)'); stop1.setAttribute('stop-opacity', '0.35');
	var stop2 = document.createElementNS(ns, 'stop');
	stop2.setAttribute('offset', '100%'); stop2.setAttribute('stop-color', 'var(--tc-speed)'); stop2.setAttribute('stop-opacity', '0.03');
	grad.appendChild(stop1); grad.appendChild(stop2); defs.appendChild(grad);

	// Gradient for upload area
	var gradUp = document.createElementNS(ns, 'linearGradient');
	gradUp.setAttribute('id', 'fg-ul-grad'+gradIdSuffix); gradUp.setAttribute('x1', '0'); gradUp.setAttribute('y1', '0');
	gradUp.setAttribute('x2', '0'); gradUp.setAttribute('y2', '1');
	var stopU1 = document.createElementNS(ns, 'stop');
	stopU1.setAttribute('offset', '0%'); stopU1.setAttribute('stop-color', 'var(--tc-ok)'); stopU1.setAttribute('stop-opacity', '0.25');
	var stopU2 = document.createElementNS(ns, 'stop');
	stopU2.setAttribute('offset', '100%'); stopU2.setAttribute('stop-color', 'var(--tc-ok)'); stopU2.setAttribute('stop-opacity', '0.02');
	gradUp.appendChild(stopU1); gradUp.appendChild(stopU2); defs.appendChild(gradUp);
	svg.appendChild(defs);

	// Background
	var bg = document.createElementNS(ns, 'rect');
	bg.setAttribute('width', w); bg.setAttribute('height', h);
	bg.setAttribute('fill', 'var(--tc-bg)'); bg.setAttribute('rx', '8');
	svg.appendChild(bg);

	// Grid lines — nice tick values, at least 5 lines, label every 2nd if crowded
	var labelEvery = gridCount > 7 ? 2 : 1;
	for (var gi = 0; gi <= gridCount; gi++) {
		var val = gi * tickStep;
		var gy = yScale(val);
		var gl = document.createElementNS(ns, 'line');
		gl.setAttribute('x1', pad.left); gl.setAttribute('x2', w - pad.right);
		gl.setAttribute('y1', gy.toFixed(1)); gl.setAttribute('y2', gy.toFixed(1));
		gl.setAttribute('stroke', 'var(--tc-border)'); gl.setAttribute('stroke-width', '0.5');
		gl.setAttribute('stroke-dasharray', '2,2');
		svg.appendChild(gl);
		if (gi > 0 && gi % labelEvery === 0) {
			var lbl = document.createElementNS(ns, 'text');
			lbl.setAttribute('x', pad.left - 4); lbl.setAttribute('y', (gy + 3).toFixed(1));
			lbl.setAttribute('text-anchor', 'end');
			lbl.setAttribute('font-size', '9'); lbl.setAttribute('fill', 'var(--tc-muted)');
			lbl.textContent = fmtSpeed(val);
			svg.appendChild(lbl);
		}
	}

	// Time axis
	var ticks = 6;
	for (var ti = 0; ti <= ticks; ti++) {
		var tx = xScale(startTime + (ti / ticks) * duration);
		var secs = Math.round(((ti / ticks) * duration) / 1000);
		var tl = document.createElementNS(ns, 'text');
		tl.setAttribute('x', tx.toFixed(1)); tl.setAttribute('y', (h - 8).toFixed(1));
		tl.setAttribute('text-anchor', 'middle');
		tl.setAttribute('font-size', '9'); tl.setAttribute('fill', 'var(--tc-muted)');
		if (secs < 60) tl.textContent = secs + 's';
		else tl.textContent = Math.floor(secs/60) + 'm' + (secs%60 ? (secs%60)+'s' : '');
		svg.appendChild(tl);
		// Vertical grid tick
		var vtick = document.createElementNS(ns, 'line');
		vtick.setAttribute('x1', tx.toFixed(1)); vtick.setAttribute('x2', tx.toFixed(1));
		vtick.setAttribute('y1', pad.top); vtick.setAttribute('y2', pad.top + gh);
		vtick.setAttribute('stroke', 'var(--tc-border)'); vtick.setAttribute('stroke-width', '0.3');
		vtick.setAttribute('stroke-dasharray', '2,4');
		svg.appendChild(vtick);
	}

	// Min/max band (translucent fill between low and high)
	if (bandData.length > 2) {
		var bandPath = 'M' + xScale(bandData[0].time).toFixed(1) + ',' + yScale(bandData[0].hi).toFixed(1);
		for (var bk = 1; bk < bandData.length; bk++) {
			bandPath += ' L' + xScale(bandData[bk].time).toFixed(1) + ',' + yScale(bandData[bk].hi).toFixed(1);
		}
		for (var bl = bandData.length - 1; bl >= 0; bl--) {
			bandPath += ' L' + xScale(bandData[bl].time).toFixed(1) + ',' + yScale(bandData[bl].lo).toFixed(1);
		}
		bandPath += ' Z';
		var bandEl = document.createElementNS(ns, 'path');
		bandEl.setAttribute('d', bandPath);
		bandEl.setAttribute('fill', 'var(--tc-speed)'); bandEl.setAttribute('opacity', '0.08');
		svg.appendChild(bandEl);
	}

	// Download area (gradient fill)
	var dlPoints = [];
	history.forEach(function(p) { dlPoints.push(xScale(p.time).toFixed(1) + ',' + yScale(p.speed).toFixed(1)); });
	var dlArea = document.createElementNS(ns, 'polyline');
	dlArea.setAttribute('points', xScale(startTime).toFixed(1)+','+(pad.top+gh)+' '+dlPoints.join(' ')+' '+xScale(endTime).toFixed(1)+','+(pad.top+gh));
	dlArea.setAttribute('fill', 'url(#fg-dl-grad'+gradIdSuffix+')'); dlArea.setAttribute('stroke', 'none');
	svg.appendChild(dlArea);

	// Download line
	var dlLine = document.createElementNS(ns, 'polyline');
	dlLine.setAttribute('points', dlPoints.join(' '));
	dlLine.setAttribute('fill', 'none'); dlLine.setAttribute('stroke', 'var(--tc-speed)');
	dlLine.setAttribute('stroke-width', '2'); dlLine.setAttribute('stroke-linejoin', 'round'); dlLine.setAttribute('stroke-linecap', 'round');
	svg.appendChild(dlLine);

	// Upload line + area (if data available)
	if (hasUpload) {
		var ulPoints = [];
		history.forEach(function(p) { ulPoints.push(xScale(p.time).toFixed(1) + ',' + yScale(p.up || 0).toFixed(1)); });
		var ulArea = document.createElementNS(ns, 'polyline');
		ulArea.setAttribute('points', xScale(startTime).toFixed(1)+','+(pad.top+gh)+' '+ulPoints.join(' ')+' '+xScale(endTime).toFixed(1)+','+(pad.top+gh));
		ulArea.setAttribute('fill', 'url(#fg-ul-grad'+gradIdSuffix+')'); ulArea.setAttribute('stroke', 'none');
		svg.appendChild(ulArea);
		var ulLine = document.createElementNS(ns, 'polyline');
		ulLine.setAttribute('points', ulPoints.join(' '));
		ulLine.setAttribute('fill', 'none'); ulLine.setAttribute('stroke', 'var(--tc-ok)');
		ulLine.setAttribute('stroke-width', '1.5'); ulLine.setAttribute('stroke-linejoin', 'round');
		ulLine.setAttribute('stroke-dasharray', '4,2'); ulLine.setAttribute('opacity', '0.8');
		svg.appendChild(ulLine);
	}

	// Limit line with label
	if (limitBps > 0) {
		var ly = yScale(limitBps);
		var ll = document.createElementNS(ns, 'line');
		ll.setAttribute('x1', pad.left); ll.setAttribute('x2', w - pad.right);
		ll.setAttribute('y1', ly.toFixed(1)); ll.setAttribute('y2', ly.toFixed(1));
		ll.setAttribute('stroke', 'var(--tc-warn)'); ll.setAttribute('stroke-width', '1.5');
		ll.setAttribute('stroke-dasharray', '6,3'); ll.setAttribute('opacity', '0.85');
		svg.appendChild(ll);
		// Label background
		var limTxt = fmtRate(limitKbit);
		var limLbl = document.createElementNS(ns, 'text');
		limLbl.setAttribute('x', (w - pad.right - 3).toFixed(1)); limLbl.setAttribute('y', (ly - 5).toFixed(1));
		limLbl.setAttribute('text-anchor', 'end');
		limLbl.setAttribute('font-size', '9'); limLbl.setAttribute('fill', 'var(--tc-warn)'); limLbl.setAttribute('font-weight', '600');
		limLbl.textContent = '⚡ ' + limTxt;
		svg.appendChild(limLbl);
	}

	// Legend (top-right corner)
	var legendX = w - pad.right - 4;
	var legendY = pad.top + 4;
	var dlLeg = document.createElementNS(ns, 'text');
	dlLeg.setAttribute('x', legendX); dlLeg.setAttribute('y', legendY);
	dlLeg.setAttribute('text-anchor', 'end'); dlLeg.setAttribute('font-size', '9');
	dlLeg.setAttribute('fill', 'var(--tc-speed)'); dlLeg.setAttribute('font-weight', '600');
	dlLeg.textContent = '↓ DL';
	svg.appendChild(dlLeg);
	if (hasUpload) {
		var ulLeg = document.createElementNS(ns, 'text');
		ulLeg.setAttribute('x', legendX); ulLeg.setAttribute('y', legendY + 12);
		ulLeg.setAttribute('text-anchor', 'end'); ulLeg.setAttribute('font-size', '9');
		ulLeg.setAttribute('fill', 'var(--tc-ok)'); ulLeg.setAttribute('font-weight', '600');
		ulLeg.textContent = '↑ UL';
		svg.appendChild(ulLeg);
	}

	// Current value annotation (last point)
	var lastP = history[history.length - 1];
	var lastX = xScale(lastP.time);
	var lastY = yScale(lastP.speed);
	var dot = document.createElementNS(ns, 'circle');
	dot.setAttribute('cx', lastX.toFixed(1)); dot.setAttribute('cy', lastY.toFixed(1));
	dot.setAttribute('r', '3.5'); dot.setAttribute('fill', 'var(--tc-speed)'); dot.setAttribute('stroke', 'var(--tc-bg)'); dot.setAttribute('stroke-width', '1.5');
	svg.appendChild(dot);
	var curLbl = document.createElementNS(ns, 'text');
	curLbl.setAttribute('x', (lastX - 6).toFixed(1)); curLbl.setAttribute('y', (lastY - 8).toFixed(1));
	curLbl.setAttribute('text-anchor', 'end'); curLbl.setAttribute('font-size', '10');
	curLbl.setAttribute('fill', 'var(--tc-speed)'); curLbl.setAttribute('font-weight', '700');
	curLbl.textContent = fmtSpeed(lastP.speed);
	svg.appendChild(curLbl);

	// Interactive crosshair overlay (mouse tracking)
	var overlay = document.createElementNS(ns, 'rect');
	overlay.setAttribute('x', pad.left); overlay.setAttribute('y', pad.top);
	overlay.setAttribute('width', gw); overlay.setAttribute('height', gh);
	overlay.setAttribute('fill', 'transparent'); overlay.setAttribute('style', 'cursor:crosshair');
	var crossV = document.createElementNS(ns, 'line');
	crossV.setAttribute('y1', pad.top); crossV.setAttribute('y2', pad.top + gh);
	crossV.setAttribute('stroke', 'var(--tc-muted)'); crossV.setAttribute('stroke-width', '0.8');
	crossV.setAttribute('stroke-dasharray', '3,2'); crossV.setAttribute('display', 'none');
	var crossH = document.createElementNS(ns, 'line');
	crossH.setAttribute('x1', pad.left); crossH.setAttribute('x2', w - pad.right);
	crossH.setAttribute('stroke', 'var(--tc-muted)'); crossH.setAttribute('stroke-width', '0.8');
	crossH.setAttribute('stroke-dasharray', '3,2'); crossH.setAttribute('display', 'none');
	var crossDot = document.createElementNS(ns, 'circle');
	crossDot.setAttribute('r', '4'); crossDot.setAttribute('fill', 'var(--tc-speed)');
	crossDot.setAttribute('stroke', '#fff'); crossDot.setAttribute('stroke-width', '2'); crossDot.setAttribute('display', 'none');
	var crossLabel = document.createElementNS(ns, 'text');
	crossLabel.setAttribute('font-size', '10'); crossLabel.setAttribute('fill', 'currentColor');
	crossLabel.setAttribute('font-weight', '600'); crossLabel.setAttribute('display', 'none');
	var crossTime = document.createElementNS(ns, 'text');
	crossTime.setAttribute('font-size', '9'); crossTime.setAttribute('fill', 'var(--tc-muted)');
	crossTime.setAttribute('display', 'none');
	// Upload crosshair dot
	var crossDotUp = document.createElementNS(ns, 'circle');
	crossDotUp.setAttribute('r', '3'); crossDotUp.setAttribute('fill', 'var(--tc-ok)');
	crossDotUp.setAttribute('stroke', '#fff'); crossDotUp.setAttribute('stroke-width', '1.5'); crossDotUp.setAttribute('display', 'none');
	var crossLabelUp = document.createElementNS(ns, 'text');
	crossLabelUp.setAttribute('font-size', '9'); crossLabelUp.setAttribute('fill', 'var(--tc-ok)');
	crossLabelUp.setAttribute('font-weight', '500'); crossLabelUp.setAttribute('display', 'none');

	svg.appendChild(crossV); svg.appendChild(crossH);
	svg.appendChild(crossDot); svg.appendChild(crossDotUp);
	svg.appendChild(crossLabel); svg.appendChild(crossLabelUp); svg.appendChild(crossTime);
	svg.appendChild(overlay);

	overlay.addEventListener('mousemove', function(ev) {
		var rect = svg.getBoundingClientRect();
		var mx = ev.clientX - rect.left;
		var ratio = (mx - pad.left) / gw;
		if (ratio < 0) ratio = 0; if (ratio > 1) ratio = 1;
		var targetTime = startTime + ratio * duration;
		// Find closest point
		var closest = 0, minDist = Infinity;
		for (var ci = 0; ci < history.length; ci++) {
			var dist = Math.abs(history[ci].time - targetTime);
			if (dist < minDist) { minDist = dist; closest = ci; }
		}
		var pt = history[closest];
		var cx = xScale(pt.time), cy = yScale(pt.speed);
		crossV.setAttribute('x1', cx.toFixed(1)); crossV.setAttribute('x2', cx.toFixed(1)); crossV.setAttribute('display', '');
		crossH.setAttribute('y1', cy.toFixed(1)); crossH.setAttribute('y2', cy.toFixed(1)); crossH.setAttribute('display', '');
		crossDot.setAttribute('cx', cx.toFixed(1)); crossDot.setAttribute('cy', cy.toFixed(1)); crossDot.setAttribute('display', '');
		crossLabel.textContent = '↓ ' + fmtSpeed(pt.speed);
		var lblX = cx + 8, lblAnchor = 'start';
		if (lblX + 80 > w - pad.right) { lblX = cx - 8; lblAnchor = 'end'; }
		crossLabel.setAttribute('x', lblX.toFixed(1)); crossLabel.setAttribute('y', (cy - 10).toFixed(1));
		crossLabel.setAttribute('text-anchor', lblAnchor); crossLabel.setAttribute('display', '');
		// Time label at bottom
		var tSec = Math.round((pt.time - startTime) / 1000);
		crossTime.textContent = tSec + 's';
		crossTime.setAttribute('x', cx.toFixed(1)); crossTime.setAttribute('y', (pad.top + gh + 14).toFixed(1));
		crossTime.setAttribute('text-anchor', 'middle'); crossTime.setAttribute('display', '');
		// Upload dot
		if (hasUpload && pt.up > 0) {
			var cyUp = yScale(pt.up);
			crossDotUp.setAttribute('cx', cx.toFixed(1)); crossDotUp.setAttribute('cy', cyUp.toFixed(1)); crossDotUp.setAttribute('display', '');
			crossLabelUp.textContent = '↑ ' + fmtSpeed(pt.up);
			crossLabelUp.setAttribute('x', lblX.toFixed(1)); crossLabelUp.setAttribute('y', (cyUp + 14).toFixed(1));
			crossLabelUp.setAttribute('text-anchor', lblAnchor); crossLabelUp.setAttribute('display', '');
		} else {
			crossDotUp.setAttribute('display', 'none'); crossLabelUp.setAttribute('display', 'none');
		}
	});
	overlay.addEventListener('mouseleave', function() {
		crossV.setAttribute('display', 'none'); crossH.setAttribute('display', 'none');
		crossDot.setAttribute('display', 'none'); crossLabel.setAttribute('display', 'none');
		crossTime.setAttribute('display', 'none');
		crossDotUp.setAttribute('display', 'none'); crossLabelUp.setAttribute('display', 'none');
	});

	return svg;
}

/* styles come from status.css — no runtime injection needed */


// ── Global overview (issue #26 item 7) ──────────────────────────────────────
// A bmon-style read of the whole router rather than one row per client: what
// the uplink is doing right now, how that splits across the physical WAN, the
// LAN bridges and the VPN tunnels, and who is responsible for it.
//
// Every number here comes from a source that already existed — per-interface
// kernel counters (trafficctl-ifaces.sh) and the per-device speed map the
// summary table is already computing — so nothing new is collected or stored
// on the router.

var ROLE_ORDER = { wan: 0, vpn: 1, lan: 2, other: 3 };
var ROLE_LABEL = { wan: 'WAN', vpn: 'VPN', lan: 'LAN', other: '—' };

function ifaceRate(hist) {
	if (!hist || !hist.length) return { down: 0, up: 0 };
	var last = hist[hist.length - 1];
	return { down: last.speed || 0, up: last.up || 0 };
}

// One interface line: badge, name, sparkline, RX/TX rate, lifetime counters.
//
// RX/TX are INTERFACE-relative, exactly as bmon reports them, and are not
// flipped to be client-relative. On the WAN that makes RX the download; on
// br-lan RX is what the LAN sent upstream. Flipping the LAN rows to match the
// user's mental model would make the two halves of the same panel mean
// different things, so the header says which way round it is instead.
function mkIfaceRow(itf, hist, globalMax) {
	var rate = ifaceRate(hist);
	var cls = 'tc-ov-row' + (itf.up ? '' : ' tc-ov-row--down');
	var badge = E('span', {
		'class': 'tc-ov-badge tc-ov-badge--' + (ROLE_ORDER[itf.role] !== undefined ? itf.role : 'other')
	}, ROLE_LABEL[itf.role] || ROLE_LABEL.other);

	var nameCell = E('span', { 'class': 'tc-ov-ifname' }, [
		E('span', { 'class': 'tc-fw-bold' }, itf.label || itf.dev)
	]);
	// The kernel device name only earns its space when it differs from the
	// friendly uci name — on "lan"/"br-lan" it does, on an unnamed device it
	// would just repeat itself.
	if (itf.label && itf.label !== itf.dev) {
		nameCell.appendChild(E('span', { 'class': 'tc-c-faint tc-ov-ifdev' }, itf.dev));
	}
	if (itf.defroute) {
		nameCell.appendChild(E('span', {
			'class': 'tc-ov-defroute',
			'data-tip': _('Carries the default route')
		}, '↗'));
	}
	// Say it on the row as well as on the expander: once expanded, a port sitting
	// next to its bridge should be identifiable without counting bytes.
	if (itf.enslaved) {
		nameCell.appendChild(E('span', {
			'class': 'tc-c-faint tc-ov-ifdev',
			'data-tip': _('Bridge port — these bytes are also counted in its bridge')
		}, _('port')));
	}
	if (!itf.up) {
		nameCell.appendChild(E('span', { 'class': 'tc-c-err tc-ov-ifdev' }, _('down')));
	}

	var sparkCell = E('span', { 'class': 'tc-ov-spark' });
	var spark = renderSparkline(hist, globalMax, 74, 18, 0);
	if (spark) {
		sparkCell.appendChild(spark);
	}

	return E('div', { 'class': cls }, [
		badge,
		nameCell,
		sparkCell,
		E('span', { 'class': 'tc-ov-rate tc-mono tc-c-speed', 'data-tip': _('Received by this interface') },
			'↓ ' + fmtSpeed(rate.down)),
		E('span', { 'class': 'tc-ov-rate tc-mono tc-c-ok', 'data-tip': _('Sent by this interface') },
			'↑ ' + fmtSpeed(rate.up)),
		E('span', { 'class': 'tc-ov-total tc-mono tc-c-muted', 'data-tip': _('Total since boot (RX / TX)') },
			fmtBytes(itf.rx_bytes) + ' / ' + fmtBytes(itf.tx_bytes))
	]);
}

// "Who is using the line right now", aggregated instead of one row per device.
// Reads self._speedMap, which pollBytes() already maintains for the summary
// table — the overview adds no second source of truth for device speed.
function mkTopTalkers(speedMap, nameByIp) {
	var list = [];
	Object.keys(speedMap || {}).forEach(function(ip) {
		var sd = speedMap[ip] || {};
		var total = (sd.current || 0) + (sd.current_up || 0);
		if (total > 0) {
			list.push({ ip: ip, down: sd.current || 0, up: sd.current_up || 0, total: total });
		}
	});
	list.sort(function(a, b) { return b.total - a.total; });
	list = list.slice(0, TOP_TALKERS);

	var body = E('div', { 'class': 'tc-ov-talkers' });
	if (!list.length) {
		body.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' }, _('No active devices')));
		return body;
	}
	// 每一条都指向该主机的实时连接详情页（点击主机名或 IP）。
	// 入口只做导航，不改变这一列表「谁正在占用带宽」的原意：速率与排序不动。
	var peak = list[0].total || 1;
	list.forEach(function(t) {
		var label = nameByIp[t.ip] && nameByIp[t.ip] !== '*' ? nameByIp[t.ip] : t.ip;
		var pct = Math.max(2, Math.round((t.total / peak) * 100));
		body.appendChild(E('div', { 'class': 'tc-ov-talker' }, [
			E('div', { 'class': 'tc-ov-talker-head' }, [
				E('span', { 'class': 'tc-ov-talker-name', 'title': _('Open host details') + ' — ' + t.ip }, [
					E('a', { 'class': 'tc-link', 'href': hostDetailUrl(t.ip) }, label),
					label !== t.ip
						? E('a', { 'class': 'tc-link tc-ov-talker-ip tc-c-muted', 'href': hostDetailUrl(t.ip) }, t.ip)
						: ''
				]),
				E('span', { 'class': 'tc-mono tc-ov-talker-rate' }, [
					E('span', { 'class': 'tc-c-speed' }, '↓ ' + fmtSpeed(t.down)),
					E('span', { 'class': 'tc-c-ok tc-ov-talker-up' }, '↑ ' + fmtSpeed(t.up))
				])
			]),
			E('div', { 'class': 'tc-ov-bar' }, [
				E('div', { 'class': 'tc-ov-bar-fill', 'style': 'width:' + pct + '%' })
			])
		]));
	});
	return body;
}

function mkOvTile(caption, value, sub, colourClass) {
	return E('div', { 'class': 'tc-ov-tile' }, [
		E('div', { 'class': 'tc-ov-tile-cap' }, caption),
		E('div', { 'class': 'tc-ov-tile-val tc-mono ' + (colourClass || '') }, value),
		E('div', { 'class': 'tc-ov-tile-sub tc-c-faint' }, sub || '')
	]);
}

// Builds the whole panel. Pure function of the state handed to it — it owns no
// timer and no listener outside the nodes it returns, so dropping the element
// is a complete teardown.
// graphWidth: 上联图的实际绘制宽度（由调用方按容器量得）。
//   此前写死 560px，而容器实测 1259px —— 图只占左半，右侧一大片空。
//   不能用 CSS `width:100%` 拉伸：SVG 带 viewBox，等比放大 2.25 倍会把
//   坐标轴与刻度文字一起放大，字号失控。故按真实宽度重绘。
function buildOverviewPanel(ifaces, ifHistory, speedMap, nameByIp, showOther, onToggleOther, pollOff, graphWidth) {
	// 卡片外壳（边框/底色/内边距）由调用方的 .tc-overview 承担 —— 统计条
	// （活跃/已阻断/WiFi）也是那张卡片的抬头。这里只返回卡片**内容**，
	// 否则会套出两层边框。
	var wrap = E('div', { 'class': 'tc-ov-body' });
	if (!ifaces || !ifaces.length) {
		wrap.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' },
			_('Collecting interface counters…')));
		return wrap;
	}

	var primary = null;
	ifaces.forEach(function(i) { if (i.primary) { primary = i; } });
	if (!primary) { primary = ifaces[0]; }
	var primaryHist = ifHistory[primary.dev] || [];
	var primaryRate = ifaceRate(primaryHist);

	var activeDevices = 0;
	Object.keys(speedMap || {}).forEach(function(ip) {
		var sd = speedMap[ip] || {};
		if ((sd.current || 0) + (sd.current_up || 0) > 0) { activeDevices++; }
	});

	// ── headline tiles ──────────────────────────────────────────────────
	var head = E('div', { 'class': 'tc-ov-tiles' }, [
		mkOvTile(_('Download') + ' · ' + (primary.label || primary.dev),
			fmtSpeed(primaryRate.down), fmtBytes(primary.rx_bytes) + ' ' + _('total'), 'tc-c-speed'),
		mkOvTile(_('Upload') + ' · ' + (primary.label || primary.dev),
			fmtSpeed(primaryRate.up), fmtBytes(primary.tx_bytes) + ' ' + _('total'), 'tc-c-ok'),
		mkOvTile(_('Active devices'), String(activeDevices),
			_('sending or receiving now'), '')
	]);
	wrap.appendChild(head);

	// ── uplink graph ────────────────────────────────────────────────────
	// One WAN, not a sum of all of them: on a failover pair the same bytes
	// would be counted twice, and on two independent uplinks the sum is a
	// number that describes neither link. Multi-WAN aggregation is issue #28.
	var graphBox = E('div', { 'class': 'tc-ov-graph' });
	// 用容器实测宽度；拿不到时（首帧、隐藏）退回 560。
	// 传入的是**外层**宽度，这里要扣掉 wrap 自身的内边距与边框，否则图会比
	// 绘图区宽 26px（实测 .tc-overview 左右各 12px padding + 1px border）。
	// 扣除值用 getComputedStyle 读，不写死像素 —— 改 CSS 时不会悄悄失配。
	var avail = 0;
	if (graphWidth) {
		var cs = window.getComputedStyle(wrap);
		avail = graphWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0)
			- (parseFloat(cs.borderLeftWidth) || 0) - (parseFloat(cs.borderRightWidth) || 0);
	}
	// height 固定 150：宽度变大只影响横向分辨率，不把图拉高。
	var w = Math.max(320, Math.round(avail || 560));
	var svg = renderFullGraph(primaryHist, 0, w, 150);
	if (svg) {
		graphBox.appendChild(svg);
	} else if (pollOff) {
		// With Poll set to Off there is no second sample coming, ever — the
		// rates are a diff of two polls. Promising one that will never arrive
		// would send the user looking for a fault instead of at the Poll chip.
		graphBox.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' },
			_('Polling is off — set the Poll interval to see throughput.')));
	} else {
		graphBox.appendChild(E('div', { 'class': 'tc-c-faint tc-ov-empty' },
			_('Waiting for a second sample…')));
	}
	wrap.appendChild(graphBox);

	// ── per-interface breakdown + top talkers ───────────────────────────
	var sorted = ifaces.slice().sort(function(a, b) {
		var ra = ROLE_ORDER[a.role] !== undefined ? ROLE_ORDER[a.role] : 3;
		var rb = ROLE_ORDER[b.role] !== undefined ? ROLE_ORDER[b.role] : 3;
		if (ra !== rb) return ra - rb;
		var sa = ifaceRate(ifHistory[a.dev]), sb = ifaceRate(ifHistory[b.dev]);
		return (sb.down + sb.up) - (sa.down + sa.up);
	});

	// One scale for every sparkline, so the rows are comparable with each
	// other at a glance — a per-row scale would make an idle tunnel look as
	// busy as the WAN.
	var globalMax = 1;
	sorted.forEach(function(i) {
		(ifHistory[i.dev] || []).forEach(function(p) {
			if (p.speed > globalMax) { globalMax = p.speed; }
		});
	});

	var ifList = E('div', { 'class': 'tc-ov-iflist' });
	var others = [];
	sorted.forEach(function(i) {
		if (i.role === 'other') { others.push(i); return; }
		ifList.appendChild(mkIfaceRow(i, ifHistory[i.dev], globalMax));
	});
	// "other" is where bridge ports (lan2, phy0-ap0 …), the DSA conduit beneath
	// the uplink, ifb mirrors including the shaper's own tctl-ifb0, and dummy
	// devices land. Their counters are real but they re-count bytes the bridge
	// or the uplink above already reports, so they are collapsed by default and
	// the expander says why — dropping them silently would hide real devices,
	// listing them flat would make the panel look like it is double-counting.
	if (others.length) {
		if (showOther) {
			others.forEach(function(i) {
				ifList.appendChild(mkIfaceRow(i, ifHistory[i.dev], globalMax));
			});
		}
		var toggle = E('div', {
			'class': 'tc-ov-more',
			'data-tip': _('Bridge ports, switch conduits and ifb mirrors. Their bytes are already counted in the bridge or uplink above.')
		}, (showOther ? '▾ ' : '▸ ') + _('Other interfaces') + ' (' + others.length + ')');
		toggle.addEventListener('click', function() { onToggleOther(!showOther); });
		ifList.appendChild(toggle);
	}

	wrap.appendChild(E('div', { 'class': 'tc-ov-cols' }, [
		E('div', { 'class': 'tc-ov-col' }, [
			E('div', { 'class': 'tc-ov-subtitle' }, _('Interfaces')),
			ifList,
			E('div', { 'class': 'tc-c-faint tc-ov-note' },
				_('↓ / ↑ are relative to the interface: on the WAN ↓ is your download, on a LAN bridge ↓ is what the LAN sent upstream.'))
		]),
		E('div', { 'class': 'tc-ov-col' }, [
			E('div', { 'class': 'tc-ov-subtitle' }, _('Top talkers')),
			mkTopTalkers(speedMap, nameByIp)
		])
	]));

	return wrap;
}

var PRIVATE_RE = /^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/;

// ── Rate-limit targets that are not a single device ─────────────────────────
//
// A limit can be placed on a block of addresses ("10.0.20.0/24") or on the
// whole network ("0.0.0.0/0") as well as on one device. Those have no row in
// the device table, so the dashboard has to recognise them to show them at all.
// A /32 is a single host written in CIDR form and belongs with the devices.
function isSubnetTarget(t) {
	if (!t || t.indexOf('/') < 0) { return false; }
	return parseInt(t.split('/')[1], 10) < 32;
}

// "a.b.c.d/m" (or a bare address, read as /32) → { base: int, mask: int }.
function parseCidr(t) {
	if (!t) { return null; }
	var parts = String(t).trim().split('/');
	var mask = parts.length > 1 ? parseInt(parts[1], 10) : 32;
	var oct = parts[0].split('.');
	if (oct.length !== 4 || isNaN(mask) || mask < 0 || mask > 32) { return null; }
	var base = 0, i, n;
	for (i = 0; i < 4; i++) {
		n = parseInt(oct[i], 10);
		if (isNaN(n) || n < 0 || n > 255 || !/^[0-9]+$/.test(oct[i])) { return null; }
		// Multiplication rather than shifts: the packed address exceeds 2^31
		// and JS bitwise operators are signed 32-bit.
		base = base * 256 + n;
	}
	return { base: base, mask: mask };
}

// Do two prefixes share any address? The shorter mask is the one that has to
// contain the other's network address.
function cidrOverlaps(a, b) {
	if (!a || !b) { return false; }
	var m = Math.min(a.mask, b.mask);
	if (m === 0) { return true; }
	var block = Math.pow(2, 32 - m);
	return Math.floor(a.base / block) === Math.floor(b.base / block);
}

function groupConnections(conns, groupBy) {
	if (groupBy === 'none') return null;
	var keyFn;
	switch(groupBy) {
		case 'host':    keyFn = function(c){ return c.host || c.dst || '?'; }; break;
		case 'service': keyFn = function(c){ return c.service || SERVICE_PORTS[c.port] || ('port '+c.port); }; break;
		case 'port':    keyFn = function(c){ return String(c.port); }; break;
		case 'proto':   keyFn = function(c){ return c.proto || '?'; }; break;
		default:        return null;
	}
	var groups = {};
	conns.forEach(function(c) {
		var k = keyFn(c);
		if (!groups[k]) groups[k] = {key: k, count: 0, bytes: 0, tcp: 0, udp: 0, sample: c};
		groups[k].count++;
		groups[k].bytes += (c.bytes || 0);
		if (c.proto === 'tcp') groups[k].tcp++;
		else if (c.proto === 'udp') groups[k].udp++;
	});
	return Object.keys(groups).map(function(k){ return groups[k]; });
}

function buildGroupedTable(groups, sortCol, sortDir) {
	var cols = [
		{ key:'key',   label: _('Group'), num:false },
		{ key:'count', label: _('Conns'), num:true  },
		{ key:'tcp',   label:'TCP',       num:true  },
		{ key:'udp',   label:'UDP',       num:true  },
		{ key:'bytes', label: _('Bytes'), num:true  }
	];

	var sorted = groups.slice().sort(function(a, b) {
		var av = a[sortCol], bv = b[sortCol];
		if (typeof av === 'number') return sortDir === 'asc' ? av - bv : bv - av;
		av = String(av||''); bv = String(bv||'');
		return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
	});

	var titleRow = E('div', { 'class': 'tr cbi-section-table-titles' }, cols.map(function(c) {
		var arrow = c.key === sortCol ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
		return E('div', { 'class': 'th', 'data-col': c.key, 'data-num': c.num ? '1' : '0' }, c.label + arrow);
	}));

	var rows = sorted.map(function(r) {
		return E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td tc-c-speed tc-fw-bold' }, escHtml(r.key)),
			E('div', { 'class': 'td tc-right tc-fw-bold' }, String(r.count)),
			E('div', { 'class': 'td tc-right tc-c-speed' }, String(r.tcp)),
			E('div', { 'class': 'td tc-right tc-c-warn' }, String(r.udp)),
			E('div', { 'class': 'td tc-right tc-mono' }, fmtBytes(r.bytes))
		]);
	});

	return E('div', { 'class': 'table tc-table tc-table--center' }, [titleRow].concat(rows));
}

function buildTable(conns, sortCol, sortDir, rdnsMode, hiddenCols) {
	var allCols = [
		{ key:'proto',   label: _('Proto'),    num:false },
		{ key:'dst',     label: _('Dst IP'),   num:false },
		{ key:'host',    label: _('Hostname'), num:false },
		{ key:'port',    label: _('Port'),     num:true  },
		{ key:'service', label: _('Service'),  num:false },
		{ key:'bytes',   label: _('Bytes'),    num:true  },
		{ key:'state',   label: _('State'),    num:false },
		{ key:'oif',     label: _('Iface'),    num:false }
	];
	var hid = hiddenCols || {};
	var cols = allCols.filter(function(c) { return !hid[c.key]; });

	var sorted = conns.slice().sort(function(a, b) {
		var av = a[sortCol], bv = b[sortCol];
		if (typeof av === 'number') return sortDir === 'asc' ? av - bv : bv - av;
		av = String(av||''); bv = String(bv||'');
		return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
	});

	var titleRow = E('div', { 'class': 'tr cbi-section-table-titles' }, cols.map(function(c) {
		var arrow = c.key === sortCol ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
		return E('div', { 'class': 'th', 'data-col': c.key, 'data-num': c.num ? '1' : '0' }, c.label + arrow);
	}));

	var rows = sorted.map(function(r) {
		var state = escHtml(r.state || '');
		var scCls = state === 'ESTABLISHED' ? ' tc-c-ok' : state === 'TIME_WAIT' ? ' tc-c-err' : state === 'CLOSE_WAIT' ? ' tc-c-warn' : '';

		var dst = r.dst || '';
		var dstEl = dst
			? E('a', { 'href': 'https://ipinfo.io/'+dst, 'target': '_blank', 'rel': 'noopener noreferrer',
			           'class':'tc-link', 'onclick': 'event.stopPropagation()' }, dst)
			: '';

		var hostCell = E('div', { 'class': 'td', 'data-dst': dst });
		if (r.host) {
			hostCell.textContent = r.host;
		} else if (rdnsMode && !PRIVATE_RE.test(dst)) {
			hostCell.innerHTML = '<span class="tc-c-faint" style="font-style:italic">' + _('resolving…') + '</span>';
		} else {
			hostCell.textContent = '—';
		}

		var cellMap = {
			proto:   E('div', { 'class': 'td tc-fw-bold tc-c-speed' }, r.proto || ''),
			dst:     E('div', { 'class': 'td tc-mono' }, dstEl),
			host:    hostCell,
			port:    E('div', { 'class': 'td tc-right tc-mono' }, String(r.port || '')),
			service: E('div', { 'class': 'td tc-c-speed' }, escHtml(r.service || (SERVICE_PORTS[r.port]||''))),
			bytes:   E('div', { 'class': 'td tc-right tc-mono tc-fw-bold' }, fmtBytes(r.bytes)),
			state:   E('div', { 'class': 'td tc-fw-bold' + scCls }, state),
			oif:     E('div', { 'class': 'td tc-mono' }, r.oif ? escHtml(r.oif) : E('span', { 'class': 'tc-c-faint' }, '—'))
		};
		var cells = cols.map(function(c) { return cellMap[c.key]; });
		return E('div', { 'class': 'tr' }, cells);
	});

	// 连接表同样居中（与设备表口径一致）。
	return E('div', { 'class': 'table tc-table tc-table--center' }, [titleRow].concat(rows));
}

// 默认隐藏的列。**必须与 cols 里的 hide 标记一致**，且单独提到模块级 ——
// 表格构建（buildSummaryTable）与列开关（colChipDefs 那段）都要用它，
// 两处各写一份必然漂移：芯片显示「已打开」而表格不渲染该列，就是漂移的症状。
//
// 这些列是为排障准备的细分数据（协议拆分、丢弃、队列深度、链路类型等），
// 平时挤在一行会把「谁在占带宽」这件事淹掉，故默认关闭、按需在「可见列」里打开。
var TC_COL_DEFAULT_HIDDEN = {
	mac: true, _spark: true, total: true,
	conn_type: true, app: true,
	_drop_packets: true, _backlog: true
};

// 某列当前是否隐藏。用户的显式选择（localStorage 里存了这个键）优先；
// 没存过则用上面的默认值。
//
// 【关键】不能只判断「键是否存在」就当作已隐藏 —— 芯片把列**打开**时若用
// `delete` 删掉键，这里就会回落到默认隐藏，于是「打开」看起来毫无作用
// （实测踩过：芯片变绿、列不出来）。故调用方打开列时必须写显式 `false`。
function isColHidden(key, hiddenCols) {
	if (!hiddenCols) return !!TC_COL_DEFAULT_HIDDEN[key];
	if (Object.prototype.hasOwnProperty.call(hiddenCols, key)) return !!hiddenCols[key];
	return !!TC_COL_DEFAULT_HIDDEN[key];
}

function buildSummaryTable(rows, sortCol, sortDir, onSort, onSelect, speedMap, dropMap, shapeMap, speedHistory, hiddenCols, onLimit) {
	// 【本仓库改动】列按爱快设备列表的形状重排，并把「每行两行显示」落实为
	//   合并列：IP/MAC 一列内上下两行、终端类型/厂商一列内上下两行、操作一列
	//   内上下两行链接。三处合并省掉 3 个独立列宽（实测每列 100~150px），
	//   16 列压到 9 列后不再需要横向滚动即可读全。
	//   默认可见即此 9 列；其余（TCP/UDP/丢弃/队列/图表/字节总量等）保留为
	//   「可见列」里的开关，默认隐藏 —— 它们是为排障准备的细分数据，
	//   平时挤在一行只会把「谁在占带宽」这件事淹掉。
	var cols = [
		// IP 与 MAC 是同一台设备的两个标识，分开成两列要在两列间来回找；
		// 合并后上行 IP、下行 MAC（小字、灰色）。
		{ key:'ip',             label:'IP / MAC',        num:false, tip: _('Local IP address — the hardware MAC is shown below it') },
		// 保留 mac 作为独立列，供仍想单列看 MAC 的人打开。默认隐藏 ——
		// 它已并入 IP 列的第二行，再单列一份就是同一串 MAC 显示两次。
		{ key:'mac',            label:'MAC',             num:false, tip: _('Hardware MAC address') },
		{ key:'conns',          label: _('Conns'),       num:true,  tip: _('Active connections in conntrack') },
		// 顺序与参照图一致：先上行速率、再下行速率，然后累计上行、累计下行。
		{ key:'_speed_up',      label: _('UL Speed'),    num:true,  tip: _('Current upload speed (bytes/sec from device to router)') },
		{ key:'_speed',         label: _('DL Speed'),    num:true,  tip: _('Current download speed (bytes/sec from router to device)') },
		{ key:'_total_up',      label: _('Total UL'),    num:true,  tip: _('Total bytes this device has uploaded, accumulated on the router. Resets on reboot; hover a cell for the start time') },
		{ key:'_total_dn',      label: _('Total DL'),    num:true,  tip: _('Total bytes this device has downloaded, accumulated on the router. Resets on reboot; hover a cell for the start time') },
		// 一列两行：上行为识别的终端类型，下行为 MAC 前缀对应的厂商（OUI）。
		{ key:'_tydev',         label: _('Type / Vendor'), num:false, tip: _('Detected device type, with the vendor looked up from the MAC address below it') },
		{ key:'name',           label: _('Name'),        num:false, tip: _('Device hostname from DHCP lease, or the name you set') },
		{ key:'_actions',       label: _('Actions'),     num:false, tip: _('Open the host detail page, or target this device with the speed limit') },
		// ── v0.6.8 起默认显示（按用户指定顺序：TCP | UDP | 互联网 | 限制）────
		//   这四列原先默认隐藏、要在「可见列」里逐个打开。它们回答的是
		//   「这台设备在用什么、有没有被限住」，属于日常判断的一部分，
		//   藏起来等于每次都要先开一遍。
		{ key:'tcp',            label:'TCP',             num:true,  tip: _('TCP bytes transferred, accumulated on the router. Not measurable while flow offload is active') },
		{ key:'udp',            label:'UDP',             num:true,  tip: _('UDP bytes transferred, accumulated on the router. Not measurable while flow offload is active') },
		{ key:'blocked',        label: _('Inet'),        num:false, tip: _('Internet access status (paused = traffic blocked)') },
		{ key:'_throttle_kbit', label: _('Limit'),       num:true,  tip: _('Speed limit: shaper (queue) or limiter (drop)') },
		// ── 以下默认隐藏，按需在「可见列」里打开 ──────────────────────────
		// 默认隐藏由模块级 TC_COL_DEFAULT_HIDDEN 统一声明（不要在这里再写
		// hide:true —— 两份真相必然漂移：芯片显示已打开而表格不渲染该列）。
		{ key:'_spark',         label: '',               num:false, tip: _('Speed graph. Window = avg time. Orange dashed line = speed limit') },
		{ key:'total',          label: _('Bytes'),       num:true,  tip: _('Total bytes transferred (download + upload), accumulated on the router. Resets on reboot; hover a cell for the start time') },
		{ key:'conn_type',      label: _('Link'),        num:false, tip: _('Connection interface (WiFi band, LAN port or routed)') },
		{ key:'app',            label: _('App'),         num:false, tip: _('Top application by traffic (needs the netifyd DPI agent)') },
		{ key:'_drop_packets',  label: _('Drop'),        num:true,  tip: _('Packets dropped by rate limiter') },
		{ key:'_backlog',       label: '📦',              num:true,  tip: _('Bytes queued in traffic shaper') }
	];

	hiddenCols = hiddenCols || {};
	// 哪些列默认隐藏由 TC_COL_DEFAULT_HIDDEN 统一决定；用户在「可见列」里的
	// 显式选择（已存进 localStorage）优先于它 —— 由 isColHidden 统一判定。
	var visibleCols = cols.filter(function(c) { return !isColHidden(c.key, hiddenCols); });

	function ipToInt(s) {
		var p = String(s||'').split('.');
		if (p.length !== 4) return 0;
		return ((parseInt(p[0])||0)*16777216 + (parseInt(p[1])||0)*65536 + (parseInt(p[2])||0)*256 + (parseInt(p[3])||0));
	}

	speedMap = speedMap || {};
	dropMap  = dropMap  || {};
	shapeMap = shapeMap || {};
	speedHistory = speedHistory || {};

	var globalSpeedMax = 0;
	Object.keys(speedHistory).forEach(function(ip) {
		var hist = speedHistory[ip];
		if (hist) {
			hist.forEach(function(h) { if (h.speed > globalSpeedMax) globalSpeedMax = h.speed; });
		}
	});

	rows.forEach(function(r) {
		var s = speedMap[r.ip];
		r._speed = s ? s.current : 0;
		r._speed_up = s ? (s.current_up || 0) : 0;
		var d = dropMap[r.ip];
		r._drop_packets = d ? d.packets : 0;
		r._drop_bytes   = d ? d.bytes   : 0;
		var sh = shapeMap[r.ip];
		r._backlog = sh ? sh.backlog : 0;
		r._throttle_kbit = (r.shape_kbit || 0) > 0 ? r.shape_kbit : (r.rate_limit_kbit || 0);
		r._throttle_mode = (r.shape_kbit || 0) > 0 ? 'shaper' : ((r.rate_limit_kbit || 0) > 0 ? 'limiter' : 'none');
	});

	var sorted = rows.slice().sort(function(a, b) {
		var av = a[sortCol], bv = b[sortCol];
		if (typeof av === 'number') {
			var diff = sortDir === 'asc' ? av - bv : bv - av;
			if (diff !== 0) return diff;
			return String(a.name || '').localeCompare(String(b.name || ''));
		}
		if (typeof av === 'boolean') return sortDir === 'asc' ? (av?1:0)-(bv?1:0) : (bv?1:0)-(av?1:0);
		if (sortCol === 'ip') {
			var d = ipToInt(av) - ipToInt(bv);
			return sortDir === 'asc' ? d : -d;
		}
		av = String(av||''); bv = String(bv||'');
		return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
	});

	var hasSpeedData = Object.keys(speedMap).length > 0;
	var titleRow = E('div', { 'class': 'tr cbi-section-table-titles' }, visibleCols.map(function(c) {
		var arrow = c.key === sortCol ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
		var compact = c.key === '_spark' || c.key === '_throttle_kbit' || c.key === '_drop_packets' || c.key === '_backlog';
		var style = (c.key === '_spark' ? 'cursor:default;width:68px;' : '') + (compact ? 'white-space:nowrap;width:1%;' : '');
		var attrs = { 'class': 'th', 'style': style || undefined, 'data-col': c.key, 'data-num': c.num ? '1' : '0' };
		if (c.tip) attrs['data-tip'] = c.tip;
		var label = c.label + arrow;
		if (c.key === '_speed' && !hasSpeedData) label = c.label + ' ';
		var th = E('div', attrs);
		th.innerHTML = label + ((c.key === '_speed' && !hasSpeedData) ? '<span class="tc-spinner"></span>' : '');
		if (c.key !== '_spark') th.addEventListener('click', function() { onSort(c.key, c.num); });
		return th;
	}));

	var tableRows = sorted.map(function(r) {
		var sd = speedMap[r.ip];
		var cellMap = {};

		var nameText = E('span', {}, escHtml(r.name));
		var renameBtn = E('span', {
			'class': 'tc-rename',
			'title': _('Rename device')
		}, '✎');
		renameBtn.addEventListener('click', function(ev) {
			ev.stopPropagation();
			promptRename(r.ip, r.name, function(newName) {
				r.name = newName || '*';
				nameText.textContent = r.name;
			});
		});
		cellMap.name = E('div', { 'class': 'td tc-fw-bold tc-c-speed tc-name-cell' }, [nameText, renameBtn]);
		// 设备名与 IP 都是进入该主机实时连接详情页的入口。链接本身
		// stopPropagation，否则点它会连带触发整行的「选中该设备」。
		cellMap.name.appendChild(E('a', {
			'class': 'tc-host-link', 'href': hostDetailUrl(r.ip),
			'title': _('Open host details'),
			'onclick': 'event.stopPropagation()'
		}, '↗'));
		var macEl = r.mac ? E('a', { 'href':'/cgi-bin/luci/admin/network/dhcp','target':'_blank','rel':'noopener','class':'tc-link','title':_('Open DHCP/DNS bindings'),'onclick':'event.stopPropagation()' }, r.mac) : '';
		cellMap.mac  = E('div', { 'class': 'td tc-mono tc-sm tc-c-muted' }, macEl || '');
		// 【本仓库改动】IP 列改为「两行式」：上行为 IP（详情页入口），下行为 MAC
		//   （小字灰色，仍链到 DHCP/DNS 绑定页）。MAC 单列已无内容可放，
		//   故默认隐藏（见 cols 里的 mac.hide），避免同一串 MAC 在一行里出现两次。
		var macLine = r.mac
			? E('div', {'class':'tc-cell-sub'}, E('a', {
				'href':'/cgi-bin/luci/admin/network/dhcp','target':'_blank','rel':'noopener',
				'class':'tc-link','title':_('Open DHCP/DNS bindings'),'onclick':'event.stopPropagation()'
			}, escHtml(r.mac)))
			: E('div', {'class':'tc-cell-sub tc-c-faint'}, '—');
		cellMap.ip = E('div', { 'class': 'td tc-mono tc-cell-stack' }, [
			E('a', {
				'class': 'tc-link', 'href': hostDetailUrl(r.ip),
				'title': _('Open host details'),
				'onclick': 'event.stopPropagation()'
			}, escHtml(r.ip)),
			macLine
		]);

		// Down and up are measured separately (bytes_in / bytes_out); showing
		// only the download half hid the entire upload side of every device.
		cellMap._speed = E('div', {
			'class': 'td tc-right tc-mono',
			'data-speed-ip': r.ip,
			'title': sd ? (_('Avg')+': '+fmtSpeed(sd.avg)+' / '+_('Max')+': '+fmtSpeed(sd.max)) : _('Calculating…')
		});
		renderSpeedCell(cellMap._speed, sd);

		cellMap._speed_up = E('div', { 'class': 'td tc-right tc-mono', 'data-speed-up-ip': r.ip, 'title': sd ? (_('Avg')+': '+fmtSpeed(sd.avg_up||0)+' / '+_('Max')+': '+fmtSpeed(sd.max_up||0)) : _('Calculating…') });
		if (sd && (sd.current_up||0) > 1024) { cellMap._speed_up.className = 'td tc-right tc-mono tc-speed-active'; cellMap._speed_up.textContent = fmtSpeed(sd.current_up); }
		else { cellMap._speed_up.className = 'td tc-right tc-mono tc-speed-idle'; cellMap._speed_up.textContent = sd ? fmtSpeed(sd.current_up||0) : '—'; }

		var sparkTip = r._throttle_kbit > 0 ? (_('Limit') + ': ' + fmtRate(r._throttle_kbit)) : '';
		cellMap._spark = E('div', { 'class': 'td tc-center', 'style': 'padding:2px 4px', 'data-spark-ip': r.ip, 'data-tip': sparkTip || undefined });
		var sparkSvg = renderSparkline(speedHistory[r.ip], globalSpeedMax, 60, 20, r._throttle_kbit);
		if (sparkSvg) cellMap._spark.appendChild(sparkSvg);

		cellMap.conns = E('div', { 'class': 'td tc-right tc-fw-bold' }, String(r.conns||0));
		// Filled from the byte poll rather than from this row, so the totals
		// keep climbing between table rebuilds (see updateTotalCells).
		cellMap.total = E('div', { 'class': 'td tc-right tc-mono tc-sm', 'data-total-ip': r.ip });
		cellMap.tcp   = E('div', { 'class': 'td tc-right tc-mono tc-sm tc-c-speed', 'data-total-tcp-ip': r.ip });
		cellMap.udp   = E('div', { 'class': 'td tc-right tc-mono tc-sm tc-c-warn', 'data-total-udp-ip': r.ip });
		renderTotalCell(cellMap.total, r.total, r._live_total, r._total_since, r._total_pending, r._total_degraded);
		renderTotalCell(cellMap.tcp,   r.tcp,   r._live_tcp,   r._total_since, r._total_pending, r._total_degraded);
		renderTotalCell(cellMap.udp,   r.udp,   r._live_udp,   r._total_since, r._total_pending, r._total_degraded);

		// 【本仓库改动】累计上行 / 累计下行分列显示（参照图的「累计上行」「累计下行」）。
		//   这两个数来自 trafficctl-totals.sh 的 bytes_out_total / bytes_in_total ——
		//   方向语义已核对：bytes_in = 下行（路由器→设备）、bytes_out = 上行（设备→路由器）。
		//   复用 renderTotalCell 以保持「降级/待采样」的三种状态一致；它按
		//   data-* 属性被 updateTotalCells 增量重绘，故两列也会随轮询增长。
		cellMap._total_up = E('div', { 'class': 'td tc-right tc-mono tc-sm', 'data-total-up-ip': r.ip });
		cellMap._total_dn = E('div', { 'class': 'td tc-right tc-mono tc-sm', 'data-total-dn-ip': r.ip });
		renderTotalCell(cellMap._total_up, r._total_up, r._live_up, r._total_since, r._total_pending, r._total_degraded);
		renderTotalCell(cellMap._total_dn, r._total_dn, r._live_dn, r._total_since, r._total_pending, r._total_degraded);

		// 【本仓库改动】终端类型 / 设备厂商：一列两行。
		//   类型由 guessDeviceType() 依主机名推断（本机无 WiFi 硬件，无法从
		//   关联表判断，故与既有逻辑一致地按名称推断）；厂商取 MAC 前缀的 OUI，
		//   由固件内的 luci-app-oui（luciOUI.decorate）异步填充 —— 它只有
		//   decorate 没有公开 lookup，故建一个游离节点让 it 写入 title/src 再读回。
		//   拿不到厂商时保留占位，不会把行撑高（两行结构始终存在）。
		var devType = guessDeviceType(r);
		var typeLine = E('div', {'class':'tc-cell-main'}, [deviceIcon(devType, 14), document.createTextNode(' ' + devTypeLabel(devType))]);
		var vendorLine = E('div', {'class':'tc-cell-sub tc-c-faint', 'data-vendor-mac': r.mac || ''}, '—');
		cellMap._tydev = E('div', { 'class': 'td tc-cell-stack' }, [typeLine, vendorLine]);
		if (r.mac) fillVendor(vendorLine, r.mac);

		// 【本仓库改动】操作列：一列两行链接（详情 / 限速）。
		var actDetail = E('a', {
			'class': 'tc-link', 'href': hostDetailUrl(r.ip),
			'title': _('Open host details'),
			'onclick': 'event.stopPropagation()'
		}, _('Details'));
		var actLimit = E('a', {
			'class': 'tc-link', 'href': 'javascript:void(0)',
			'title': _('Set this device\'s speed limit'),
			'onclick': 'event.stopPropagation()'
		}, _('Limit'));
		actLimit.addEventListener('click', function(ev) {
			ev.stopPropagation();
			// 【本仓库改动 v0.6.9】原来只是把目标设为该设备、再让用户滚回卡片
			//   去点速率 —— 两步且要来回找。现直接在这台设备旁弹出限速设置。
			//   找不到回调时退回旧行为（选中该设备），不至于点了没反应。
			if (typeof onLimit === 'function') onLimit(actLimit, r.ip, r.name);
			else onSelect(r.ip, r.name);
		});
		cellMap._actions = E('div', { 'class': 'td tc-actions tc-cell-stack' }, [actDetail, actLimit]);

		var inetBadge = r.blocked
			? E('span', { 'class': 'tc-c-warn tc-fw-bold' }, '⏸ ' + _('blocked'))
			: E('span', { 'class': 'tc-c-faint' }, '—');
		cellMap.blocked = E('div', { 'class': 'td tc-center' }, inetBadge);

		var linkBadge;
		var ct = r.conn_type || 'ethernet';
		var isWifi = (ct === 'wifi' || ct === '2.4G' || ct === '5G' || ct === '6G');
		if (ct === '?') {
			var tip = _('Unknown — device unreachable');
			if (r.conn_last) {
				var parts = r.conn_last.split('@');
				var lastType = parts[0] || '';
				var lastTs = parseInt(parts[1], 10);
				if (lastTs) {
					var ago = Math.floor((Date.now()/1000) - lastTs);
					var agoStr = ago < 60 ? ago + 's' : ago < 3600 ? Math.floor(ago/60) + 'm' : Math.floor(ago/3600) + 'h';
					tip = _('Last seen') + ': ' + lastType + ', ' + agoStr + ' ' + _('ago');
				}
			}
			linkBadge = E('span', { 'class': 'tc-c-faint', 'style': 'cursor:help', 'title': tip }, '?');
		} else if (ct === 'routed') {
			linkBadge = E('span', { 'class': 'tc-c-muted', 'style': 'cursor:help', 'title': _('Behind a downstream router (routed subnet)') }, '⇄ ' + _('routed'));
		} else if (isWifi) {
			var wLabel = ct === 'wifi' ? 'WiFi' : ct;
			linkBadge = r.wifi_blocked
				? E('span', { 'class': 'tc-c-warn tc-fw-bold', 'style': 'text-decoration:line-through' }, wLabel)
				: E('span', { 'class': 'tc-c-speed' }, wLabel);
		} else {
			var ethLabel = (ct === 'ethernet') ? 'eth' : ct;
			linkBadge = E('span', { 'class': 'tc-c-muted' }, [mkEthIcon(14), document.createTextNode(ethLabel)]);
		}
		cellMap.conn_type = E('div', { 'class': 'td tc-center' }, linkBadge);
		// A WiFi block used to show in the row only as the line-through above,
		// which lives inside the isWifi branch — so it disappeared from the row
		// in the two cases that matter most: a block that WORKED (the device
		// stops associating, the cell falls through to "?" or eth) and a device
		// blocked while sitting on cable. Mark it in every branch, with a label
		// and a tooltip rather than a text decoration nobody reads as "blocked".
		if (r.wifi_blocked) {
			cellMap.conn_type.appendChild(mkWifiBlockBadge(r.wifi_block_pending));
		}

		var appBadge;
		if (r.app) {
			var appDetail = netifyMap[r.ip];
			var appTip = _('Top application by traffic');
			if (appDetail && appDetail.apps && appDetail.apps.length) {
				appTip = appDetail.apps.slice(0, 5).map(function(a) {
					return a.name + ' — ' + fmtBytes(a.bytes);
				}).join('\n');
			}
			appBadge = E('span', { 'class': 'tc-app-badge', 'title': appTip }, escHtml(r.app));
		} else {
			appBadge = E('span', { 'class': 'tc-c-faint' }, '—');
		}
		cellMap.app = E('div', { 'class': 'td tc-center' }, appBadge);

		var throttleBadge;
		if (r._throttle_mode === 'shaper') { throttleBadge = E('span', { 'class': 'tc-c-speed tc-fw-bold', 'title': _('Shaper (tc/HTB queue)') }, '≈ ' + fmtRate(r._throttle_kbit)); }
		else if (r._throttle_mode === 'limiter') { throttleBadge = E('span', { 'class': 'tc-c-warn tc-fw-bold', 'title': _('Limiter (nft drop)') }, '⚡ ' + fmtRate(r._throttle_kbit)); }
		else { throttleBadge = E('span', { 'class': 'tc-c-faint' }, '—'); }
		cellMap._throttle_kbit = E('div', { 'class': 'td tc-center' }, throttleBadge);

		var dp = r._drop_packets || 0;
		var dropBadge = dp > 0 ? E('span', { 'class': 'tc-c-err tc-fw-bold', 'title': fmtBytes(r._drop_bytes||0)+' '+_('dropped') }, String(dp)) : E('span', { 'class': 'tc-c-faint' }, '—');
		cellMap._drop_packets = E('div', { 'class': 'td tc-center', 'data-drop-ip': r.ip }, dropBadge);

		var bl = r._backlog || 0;
		var backlogBadge = bl > 0 ? E('span', { 'class': 'tc-c-speed tc-fw-bold', 'title': _('Bytes queued in tc') }, fmtBytes(bl)) : E('span', { 'class': 'tc-c-faint' }, '—');
		cellMap._backlog = E('div', { 'class': 'td tc-center', 'data-backlog-ip': r.ip }, backlogBadge);

		var cells = visibleCols.map(function(c) { return cellMap[c.key]; });
		var row = E('div', { 'class': 'tr', 'title': _('Click to inspect') + ' ' + r.name }, cells);
		row.addEventListener('click', function() { addRecentDevice(r.ip, r.name); onSelect(r.ip, r.name); });
		return row;
	});

	// 【本仓库改动】表头与单元格一律居中对齐（.tc-table--center）。
	//   原先表头左对齐、数字列右对齐、文字列左对齐 —— 三种对齐混在一行里，
	//   设备多时列与列之间看起来是错位的。统一居中后每列的标题与内容落在
	//   同一条中轴上。
	//   注意只加在**真正的表格**上：扩展统计面板（buildExtendedStatsPanel）
	//   也用 .tc-table，但它是「标签 — 数值」两栏行，居中会读不成列表。
	var tblEl = E('div', { 'class': 'table tc-table tc-table--rows-clickable tc-table--center' }, [titleRow].concat(tableRows));
	// 【本仓库改动】列宽改由**这里按每列的最小可用宽度**算出来，不再只靠 CSS
	//   里的百分比。原因：百分比是「占表宽的比例」，列一多（用户可在「可见列」
	//   里把 11 个隐藏列全开，最多 20 列）各列比例被摊薄 —— 实测图表 / 限制 /
	//   丢弃 / 队列四列被压到 **11px**，MAC 被挤成三行。
	//   做法：给每列一个最小像素预算，总和即表的 min-width；每列的百分比按
	//   「预算 / 总和」得出。于是：
	//     · 容器窄于总和 → 表取 min-width，每列恰好拿到自己的预算，横向滚动；
	//     · 容器宽于总和 → 表铺满容器，各列按同一比例变大（自然拉伸）。
	//   两种情形都不会出现「某列被摊到 11px」。
	var COL_MIN_PX = {
		ip: 150, mac: 130, conns: 58,
		_speed: 84, _speed_up: 84, _total_up: 84, _total_dn: 84,
		total: 78, tcp: 78, udp: 78,
		_tydev: 130, name: 170, _actions: 76,
		_spark: 70, blocked: 70, conn_type: 82, app: 88,
		_throttle_kbit: 78, _drop_packets: 64, _backlog: 64
	};
	var totalMin = 0;
	visibleCols.forEach(function(c) { totalMin += (COL_MIN_PX[c.key] || 80); });
	tblEl.style.minWidth = Math.max(860, totalMin) + 'px';
	// 百分比之和恰为 100%，故 fixed 布局没有「余量按比例摊分」的问题。
	visibleCols.forEach(function(c, i) {
		var px = COL_MIN_PX[c.key] || 80;
		var pct = (px / totalMin * 100);
		titleRow.children[i].style.width = pct.toFixed(3) + '%';
	});
	return tblEl;
}

function setStatus(el, type, msg) {
	var cls = {loading: '', ok: 'success', error: 'error', action: 'warning'};
	el.className = 'alert-message ' + (cls[type] || '');
	el.innerHTML = type === 'loading' ? '<span class="tc-spinner"></span>'+escHtml(msg) : escHtml(msg);
	// 任何**动作**写的状态都会摘掉「例行轮询错误」标记 —— 见 clearRoutineStatus()。
	// 不摘的话，动作成功消息会被下一次例行成功轮询当成自己的旧错误清掉。
	el.removeAttribute('data-routine');
}

// 例行轮询专用的状态写入器（v0.6.7）。
// 例行轮询（runAll / runSingle）此前每秒往状态行写「扫描所有设备中…」→「✓ 完成」，
// 1 秒档位下这一行不停地闪 —— 它是**噪声**，不是信息：轮询本来就该是看不见的。
// 现在例行轮询**只在失败时**写状态；成功时若上一行是它自己的错误，就清掉。
// 动作类反馈（限速/切断/WiFi 黑名单）仍走 setStatus，逐字保留 —— 那些是
// 用户主动触发、必须看到结果的操作，不能与轮询噪声一起被删。
function setRoutineStatus(el, type, msg) {
	if (type === 'error') {
		setStatus(el, type, msg);
		el.setAttribute('data-routine', '1');
		return;
	}
	// 成功：只清理**本函数之前写下的**错误，不碰动作消息。
	if (el.getAttribute('data-routine') === '1') {
		el.className = 'alert-message tc-hidden';
		el.innerHTML = '';
		el.removeAttribute('data-routine');
	}
}

function updateUrlParams(opts) {
	var params = new URLSearchParams();
	if (opts.lastIp && opts.lastIp !== '__all__') params.set('ip', opts.lastIp);
	if (opts.refresh && opts.refresh > 0) params.set('refresh', String(opts.refresh));
	if (opts.pollInterval) params.set('poll', String(opts.pollInterval));
	if (opts.avgWindow && opts.avgWindow !== siteDefaults.avgWindow) params.set('avg', String(opts.avgWindow));
	if (opts.avgMethod && opts.avgMethod !== 'simple') params.set('method', opts.avgMethod);
	if (opts.extendedStats) params.set('extended', '1');
	// 【v0.6.8】不再写 overview 参数：概览已常显，没有开关可记。
	if (opts.rdns) params.set('rdns', '1');
	var newUrl = window.location.pathname + (params.toString() ? '?' + params.toString() : '');
	// Selecting a different device is a real navigation step, so push it and let
	// back/forward (including mobile back gestures and mouse back buttons) move
	// between devices. Option tweaks — columns, filters, intervals — only rewrite
	// the current entry, so they don't flood the history stack.
	var curIp = new URLSearchParams(window.location.search).get('ip') || '__all__';
	var newIp = opts.lastIp || '__all__';
	var state = { ip: newIp };
	if (curIp !== newIp) history.pushState(state, '', newUrl);
	else history.replaceState(state, '', newUrl);
}

function applyUrlParams(opts) {
	var urlParams = new URLSearchParams(window.location.search);
	var paramIp = urlParams.get('ip');
	var paramRefresh = urlParams.get('refresh');
	var paramPoll = urlParams.get('poll');
	var paramAvg = urlParams.get('avg');
	var paramMethod = urlParams.get('method');
	var paramExtended = urlParams.get('extended');
	var paramRdns = urlParams.get('rdns');

	if (paramIp) opts.lastIp = paramIp;
	if (paramRefresh) opts.refresh = parseInt(paramRefresh) || 0;
	if (paramPoll) opts.pollInterval = parseInt(paramPoll) || 0;
	if (paramAvg) opts.avgWindow = parseInt(paramAvg) || siteDefaults.avgWindow;
	if (paramMethod && (paramMethod === 'ewma' || paramMethod === 'simple')) opts.avgMethod = paramMethod;
	if (paramExtended === '1') opts.extendedStats = true;
	// 【v0.6.8】概览已常显。旧的 `?overview=1` 链接不再需要，但也不能因此
	//   报错或改变行为 —— 直接读掉忽略即可（loadOpts 会剥掉它）。
	if (paramRdns === '1') opts.rdns = true;
	return opts;
}

function buildExtendedStatsPanel(ip, shapeMap, dropMap, speedMap) {
	var sm = shapeMap[ip];
	var dm = dropMap[ip];
	var spd = speedMap[ip];

	var tooltips = {
		'Drops': _('packets dropped by queue overflow'),
		'Overlimits': _('rate exceeded events'),
		'ECN marks': _('congestion signals without drop'),
		'Flows': _('active concurrent connections in queue'),
		'Queue memory': _('bytes allocated by the queue discipline'),
		'Lended / Borrowed': _('own-rate vs parent-rate packets'),
		'Utilization': _('current speed as percentage of rate limit'),
		'Packets dropped': _('traffic discarded by nft policer'),
		'Bytes dropped': _('traffic discarded by nft policer'),
		'Drop ratio': _('percentage of total traffic that was dropped')
	};
	var rows = [];

	function addRow(label, value, color) {
		var tip = tooltips[label] || '';
		rows.push(E('div', { 'class': 'tr' }, [
			E('div', { 'class': 'td tc-c-muted', 'title': tip }, label),
			E('div', { 'class': 'td tc-right tc-mono tc-fw-bold', 'style': color ? 'color:' + color : '' }, value)
		]));
	}

	if (sm && sm.rate_kbit > 0) {
		if (sm.drops != null) addRow(_('Drops'), String(sm.drops), sm.drops > 0 ? 'var(--tc-err)' : null);
		if (sm.overlimits != null) addRow(_('Overlimits'), String(sm.overlimits), sm.overlimits > 0 ? 'var(--tc-warn)' : null);
		if (sm.ecn_mark != null) addRow(_('ECN marks'), String(sm.ecn_mark), sm.ecn_mark > 0 ? 'var(--tc-warn)' : null);
		if (sm.new_flows != null || sm.old_flows != null) {
			addRow(_('Flows'), (sm.new_flows || 0) + ' ' + _('new') + ' / ' + (sm.old_flows || 0) + ' ' + _('old'), null);
		}
		if (sm.memory_used != null) addRow(_('Queue memory'), fmtBytes(sm.memory_used), null);
		if (sm.lended != null || sm.borrowed != null) {
			addRow(_('Lended') + ' / ' + _('Borrowed'), (sm.lended || 0) + ' / ' + (sm.borrowed || 0), null);
		}
		if (spd && sm.rate_kbit > 0) {
			var currentBps = spd.current || 0;
			var rateBytes = (sm.rate_kbit * 1000) / 8;
			var util = rateBytes > 0 ? ((currentBps / rateBytes) * 100) : 0;
			var utilColor = util > 95 ? 'var(--tc-err)' : util > 70 ? 'var(--tc-warn)' : 'var(--tc-ok)';
			addRow(_('Utilization'), util.toFixed(1) + '%', utilColor);
		}
	} else if (dm && dm.rate_kbit > 0) {
		addRow(_('Packets dropped'), String(dm.packets || 0), (dm.packets || 0) > 0 ? 'var(--tc-err)' : null);
		addRow(_('Bytes dropped'), fmtBytes(dm.bytes || 0), (dm.bytes || 0) > 0 ? 'var(--tc-err)' : null);
		var dropBytes = dm.bytes || 0;
		var passBytes = dm.pass_bytes || 0;
		var totalBytes = dropBytes + passBytes;
		var dropRatio = totalBytes > 0 ? ((dropBytes / totalBytes) * 100) : 0;
		var drColor = dropRatio > 10 ? 'var(--tc-err)' : dropRatio > 2 ? 'var(--tc-warn)' : null;
		addRow(_('Drop ratio'), dropRatio.toFixed(1) + '%', drColor);
	}

	if (rows.length === 0) {
		return E('div', { 'class': 'tc-ext-panel', 'style': 'color:var(--tc-muted)' }, _('No extended stats available for this device.'));
	}

	return E('div', { 'class': 'tc-ext-panel' }, [
		E('div', { 'class': 'tc-ext-panel__title' }, _('Extended Statistics')),
		E('div', { 'class': 'table tc-table' }, rows)
	]);
}

function buildExtendedStatsLegend(shapeMap, dropMap) {
	var labelStyle = 'color:var(--tc-muted);font-size:12px';
	var valueStyle = 'font-family:monospace;font-weight:600;color:currentColor;font-size:13px';
	var totalDrops = 0, totalOverlimits = 0, totalEcn = 0, totalMemory = 0;
	var totalDropPkts = 0, totalDropBytes = 0;
	var shapedCount = 0, limitedCount = 0, limitedSubnets = 0;

	Object.keys(shapeMap).forEach(function(ip) {
		var sm = shapeMap[ip];
		if (sm && sm.rate_kbit > 0) {
			shapedCount++;
			totalDrops += (sm.drops || 0);
			totalOverlimits += (sm.overlimits || 0);
			totalEcn += (sm.ecn_mark || 0);
			totalMemory += (sm.memory_used || 0);
		}
	});
	Object.keys(dropMap).forEach(function(ip) {
		var dm = dropMap[ip];
		if (dm && dm.rate_kbit > 0) {
			// A subnet limit covers many devices and is counted apart from
			// them: folded in, it read as one more "limited device" that no
			// row in the table below corresponded to.
			if (isSubnetTarget(ip)) {
				limitedSubnets++;
			} else {
				limitedCount++;
			}
			totalDropPkts += (dm.packets || 0);
			totalDropBytes += (dm.bytes || 0);
		}
	});

	var rows = [];
	function addRow(label, value, color) {
		var vs = color ? valueStyle + ';color:' + color : valueStyle;
		rows.push(E('div', { 'class': 'tc-ext-row' }, [
			E('span', { 'style': labelStyle }, label),
			E('span', { 'style': vs }, value)
		]));
	}

	if (shapedCount > 0) {
		addRow(_('Shaped devices'), String(shapedCount), 'var(--tc-speed)');
		addRow(_('Total drops'), String(totalDrops), totalDrops > 0 ? 'var(--tc-err)' : null);
		addRow(_('Overlimits'), String(totalOverlimits), totalOverlimits > 0 ? 'var(--tc-warn)' : null);
		addRow(_('ECN marks'), String(totalEcn));
		addRow(_('Total queue memory'), fmtBytes(totalMemory));
	}
	if (limitedCount > 0) {
		addRow(_('Limited devices'), String(limitedCount), 'var(--tc-warn)');
	}
	if (limitedSubnets > 0) {
		addRow(_('Limited subnets'), String(limitedSubnets), 'var(--tc-warn)');
	}
	if (limitedCount > 0 || limitedSubnets > 0) {
		addRow(_('Total dropped'), totalDropPkts + ' ' + _('pkts') + ' / ' + fmtBytes(totalDropBytes), totalDropPkts > 0 ? 'var(--tc-err)' : null);
	}
	if (rows.length === 0) {
		rows.push(E('div', { 'style': 'padding:4px 0;color:var(--tc-muted)' }, _('No extended stats available.')));
	}

	return E('div', { 'class': 'tc-ext-panel tc-ext-panel--sticky' }, [
		E('div', { 'class': 'tc-ext-panel__title' }, _('Extended Statistics') + ' (' + _('all devices') + ')'),
		E('div', { 'class': 'tc-ext-col-flex' }, rows)
	]);
}

function guessDeviceType(d) {
	var n = (d.name || '').toLowerCase();
	if (/iphone|android|pixel|galaxy|huawei|xiaomi|redmi|poco|oneplus|realme|oppo|vivo|phone/.test(n)) return 'phone';
	if (/ipad|tab|kindle/.test(n)) return 'tablet';
	if (/tv|roku|firestick|chromecast|appletv|hisense|samsung.*tv|lg.*tv|sony.*tv/.test(n)) return 'tv';
	if (/macbook|laptop|notebook|thinkpad|lenovo/.test(n)) return 'laptop';
	if (/imac|desktop|pc|workstation|mini/.test(n)) return 'desktop';
	if (/echo|alexa|homepod|nest|speaker/.test(n)) return 'speaker';
	if (/cam|camera|doorbell|ring/.test(n)) return 'camera';
	if (/printer|brother|hp.*jet|epson/.test(n)) return 'printer';
	if (/switch|router|ap|eap|ubnt|unifi/.test(n)) return 'network';
	return 'device';
}

function deviceIcon(type, size) {
	var icons = {
		phone:   '📱', tablet:  '📱', tv:      '📺', laptop:  '💻',
		desktop: '🖥️', speaker: '🔊', camera:  '📷', printer: '🖨️',
		network: '🌐', device:  '⬡'
	};
	return E('span', {'style':'font-size:'+(size||18)+'px;line-height:1'}, icons[type] || icons.device);
}

// 终端类型的中文名，用于「终端类型 / 厂商」列的第一行。
// 与 deviceIcon 的键一一对应；漏一个就会显示英文键名。
function devTypeLabel(type) {
	var labels = {
		phone:   _('Phone'),    tablet:  _('Tablet'), tv:      _('TV'),
		laptop:  _('Laptop'),   desktop: _('Desktop'), speaker: _('Speaker'),
		camera:  _('Camera'),   printer: _('Printer'), network: _('Network'),
		device:  _('Device')
	};
	return labels[type] || labels.device;
}

// 由 MAC 前缀查设备厂商，写入 el 的文本。
//
// 数据来自固件随包安装的 luci-app-oui（实测 100 KB 厂商库，能查到
// Xiaomi / Midea 等）。但它只导出 decorate / setDevices，**没有公开的
// lookup**，故这里建一个游离节点让 decorate 把厂商写进 icon.title，再读回来。
//
// 三种结果都要与「还没查出来」区分开，否则一列 '—' 分不清是没查到还是仍在查：
//   厂商名（Xiaomi）/ 'Private MAC'（随机化 MAC，无厂商可查）/ 保持 '—'（查不到）。
// 本机无 luci-app-oui 时 decorate 不存在，此处静默保持 '—'，不抛错 ——
// 它是锦上添花的列，不该让设备表整块渲染失败。
function fillVendor(el, mac) {
	if (!mac) return;
	function doFill() {
		try {
			var probe = E('div', {});
			window.luciOUI.decorate(probe, mac);
			var icon = probe.querySelector('.luci-oui-icon');
			var title = icon && icon.title;
			// decorate 先写 'Unknown vendor' 再异步覆盖，故要等一轮宏任务再读。
			setTimeout(function() {
				var ic2 = probe.querySelector('.luci-oui-icon');
				var t2 = ic2 && ic2.title;
				if (t2 && t2 !== 'Unknown vendor' && t2 !== 'Private MAC') {
					el.textContent = t2;
					el.title = t2 + ' (' + mac + ')';
					el.classList.remove('tc-c-faint');
				} else if (t2 === 'Private MAC') {
					el.textContent = _('Private MAC');
					el.title = _('This MAC is randomized by the client, so no vendor can be looked up.');
				}
			}, 400);
		} catch (e) {
			// 保持 '—'，不抛出：厂商列是附加信息。
		}
	}
	if (window.luciOUI && window.luciOUI.decorate) {
		doFill();
		return;
	}
	// oui.js 未被任何视图加载过 —— 按需载入一次，失败也不影响表格。
	var s = document.createElement('script');
	s.src = '/luci-static/resources/oui/oui.js';
	s.onload = doFill;
	s.onerror = function() { /* 保持 '—' */ };
	document.head.appendChild(s);
}


function buildSearchSelect(devices, placeholder, onSelect) {
	var selectedValue = '__all__';
	var recentIps = [];
	var MAX_RECENT = 5;
	var wrapper = E('div', { 'class': 'tc-search-wrapper' });
	var input = E('input', {
		'type': 'text',
		'placeholder': placeholder,
		'autocomplete': 'off',
		'class': 'tc-search-input'
	});
	var clearBtn = E('span', { 'class': 'tc-search-clear tc-hidden' }, '×');
	var dropdown = E('div', { 'class': 'tc-search-dropdown tc-hidden' });
	wrapper.appendChild(input);
	wrapper.appendChild(clearBtn);
	wrapper.appendChild(dropdown);

	var highlightIdx = -1;

	function addToRecent(ip) {
		recentIps = recentIps.filter(function(r) { return r !== ip; });
		recentIps.unshift(ip);
		if (recentIps.length > MAX_RECENT) recentIps.length = MAX_RECENT;
	}

	function highlightMatch(text, q) {
		if (!q) return escHtml(text);
		var lower = text.toLowerCase();
		var idx = lower.indexOf(q);
		if (idx === -1) return escHtml(text);
		return escHtml(text.substring(0, idx)) + '<b>' + escHtml(text.substring(idx, idx + q.length)) + '</b>' + escHtml(text.substring(idx + q.length));
	}

	function deviceLabel(d) {
		return d.name + '  —  ' + d.ip + (d.mac ? '  (' + d.mac + ')' : '');
	}

	function mkItem(it, idx, q) {
		var item = E('div', { 'class': 'tc-dropdown-item', 'data-value': it.value });
		if (q && it.value !== '__all__') {
			item.innerHTML = highlightMatch(it.label, q);
		} else {
			item.textContent = it.label;
		}
		if (it.section) {
			item.className = 'tc-dropdown-item--section';
			return item;
		}
		if (it.value === '__all__') {
			item.className = 'tc-dropdown-item tc-dropdown-item--all';
		}
		item.addEventListener('mousedown', function(ev) {
			ev.preventDefault();
			selectItem(it.value, it.label);
		});
		item.addEventListener('mouseenter', function() {
			highlightIdx = idx;
			updateHighlight(dropdown);
		});
		return item;
	}

	function renderItems(filter) {
		while (dropdown.firstChild) dropdown.removeChild(dropdown.firstChild);
		var q = (filter || '').toLowerCase();
		var items = [];
		items.push({ value: '__all__', label: '— ' + _('All active devices') + ' —', searchText: '' });

		if (!q && recentIps.length > 0) {
			items.push({ section: true, label: _('Recent'), value: '_hdr_recent' });
			recentIps.forEach(function(ip) {
				var d = devices.filter(function(dev) { return dev.ip === ip; })[0];
				if (d) items.push({ value: d.ip, label: deviceLabel(d), searchText: '' });
			});
			items.push({ section: true, label: _('All'), value: '_hdr_all' });
		}

		devices.forEach(function(d) {
			var st = (d.name + ' ' + d.ip + ' ' + (d.mac||'')).toLowerCase();
			if (!q || st.indexOf(q) !== -1) {
				items.push({ value: d.ip, label: deviceLabel(d), searchText: st });
			}
		});

		highlightIdx = -1;
		var actionIdx = 0;
		items.forEach(function(it) {
			var item = mkItem(it, actionIdx, q);
			dropdown.appendChild(item);
			if (!it.section) actionIdx++;
		});
	}

	function updateHighlight(dd) {
		var actionIdx = 0;
		Array.prototype.forEach.call(dd.children, function(el) {
			if (el.getAttribute('data-value') && el.getAttribute('data-value').indexOf('_hdr_') === 0) return;
			el.style.background = actionIdx === highlightIdx ? 'var(--tc-hover)' : '';
			actionIdx++;
		});
	}

	function selectItem(value, label, silent) {
		selectedValue = value;
		if (value === '__all__') {
			input.value = '';
			clearBtn.classList.add('tc-hidden');
		} else {
			addToRecent(value);
			input.value = label.replace(/\s+\(.*\)$/, '');
			clearBtn.classList.remove('tc-hidden');
		}
		dropdown.classList.add('tc-hidden');
		if (!silent) onSelect(value);
	}

	input.addEventListener('focus', function() {
		this.style.cursor = 'text';
		renderItems(input.value);
		dropdown.classList.remove('tc-hidden');
	});
	input.addEventListener('blur', function() {
		this.style.cursor = 'pointer';
		setTimeout(function() { dropdown.classList.add('tc-hidden'); }, 150);
	});
	input.addEventListener('click', function() {
		renderItems(input.value);
		dropdown.classList.remove('tc-hidden');
	});
	input.addEventListener('input', function() {
		renderItems(input.value);
		dropdown.classList.remove('tc-hidden');
	});
	input.addEventListener('keydown', function(ev) {
		var actionItems = [];
		Array.prototype.forEach.call(dropdown.children, function(el) {
			var v = el.getAttribute('data-value');
			if (v && v.indexOf('_hdr_') !== 0) actionItems.push(el);
		});
		if (ev.key === 'ArrowDown') {
			ev.preventDefault();
			highlightIdx = Math.min(highlightIdx + 1, actionItems.length - 1);
			updateHighlight(dropdown);
		} else if (ev.key === 'ArrowUp') {
			ev.preventDefault();
			highlightIdx = Math.max(highlightIdx - 1, 0);
			updateHighlight(dropdown);
		} else if (ev.key === 'Enter') {
			ev.preventDefault();
			if (highlightIdx >= 0 && highlightIdx < actionItems.length) {
				var el = actionItems[highlightIdx];
				selectItem(el.getAttribute('data-value'), el.textContent);
			}
		} else if (ev.key === 'Escape') {
			dropdown.classList.add('tc-hidden');
			input.blur();
		}
	});
	clearBtn.addEventListener('click', function() {
		selectItem('__all__', '');
		input.focus();
	});

	return {
		el: wrapper,
		getValue: function() { return selectedValue; },
		setValue: function(val, label) { selectItem(val, label || val, true); },
		updateDevices: function(newDevices) { devices = newDevices; }
	};
}

return view.extend({
	_timer:        null,
	_bytesTimer:   null,
	_dropTimer:    null,
	_shapeTimer:   null,
	_bytesHistory: {},
	_speedHistory: {},
	_fullHistory:  {},
	_speedMap:     {},
	_totalsMap:    {},
	_dropMap:      {},
	// Limits whose target is a block of addresses rather than one device.
	_subnetLimits: [],
	_shapeMap:     {},
	_speedEwma:    {},
	_speedEwmaUp:  {},
	// Global overview state. _ifBytes holds the previous raw counter sample per
	// interface (the overview diffs two samples exactly as pollBytes does for
	// devices), _ifHistory the derived rates, _ifMeta the last role/label map.
	_ifBytes:      {},
	_ifHistory:    {},
	_ifMeta:       [],
	_deviceTimer:  null,
	_pollMode:     null,
	_onPopState:   null,
	_rdnsCache:    {},
	_sortCol:    'bytes',
	_sortDir:    'desc',
	_sumCol:     'name',
	_sumDir:     'asc',
	_hiddenCols: {},
	_queryGen:   0,

	load: function() {
		// config_get rides along with the leases so the router-wide Poll and
		// Window defaults are known BEFORE the first render. Fetching them
		// afterwards would paint the chips with the built-in numbers and then
		// move them, and would start the poll timer at the wrong interval.
		// It is allowed to fail: siteDefaults already holds the shipped values.
		return Promise.all([
			fs.read('/tmp/dhcp.leases').catch(function() { return ''; }),
			callConfigGet().catch(function() { return null; })
		]);
	},

	render: function(loaded) {
		var leasesRaw = loaded[0];
		var siteCfg = loaded[1];
		if (siteCfg) {
			if (typeof siteCfg.poll_interval === 'number') {
				siteDefaults.pollInterval = siteCfg.poll_interval;
			}
			if (typeof siteCfg.avg_window === 'number' && siteCfg.avg_window > 0) {
				siteDefaults.avgWindow = siteCfg.avg_window;
			}
			// 【本仓库补丁】整表刷新默认值也允许由路由端下发（UCI
			// trafficctl.main.refresh_interval）。字段缺失时保持内置默认 5s。
			if (typeof siteCfg.refresh_interval === 'number' && siteCfg.refresh_interval >= 0) {
				siteDefaults.refreshInterval = siteCfg.refresh_interval;
			}
		}
		var self = this;
		var opts = loadOpts();
		opts = applyUrlParams(opts);
		saveOpts(opts);
		var devices = [];
		(leasesRaw || '').split('\n').forEach(function(line) {
			var p = line.trim().split(/\s+/);
			if (p.length >= 4 && p[2] && p[3] && p[3] !== '*') {
				devices.push({ ip: p[2], name: p[3], mac: p[1] || '' });
			}
		});
		devices.sort(function(a, b) { return a.name.localeCompare(b.name); });

		var savedIp = opts.lastIp || '__all__';

		function onDeviceSelect(value) {
			var o = loadOpts(); o.lastIp = value; saveOpts(o); updateUrlParams(o);
			if (value !== '__all__') {
				var _nd = devices.filter(function(d) { return d.ip === value; })[0];
				addRecentDevice(value, _nd ? _nd.name : null);
			}
			renderRecentChips();
			updateModeUI();
			runQuery();
		}

		var searchSelect = buildSearchSelect(devices, _('Search device (name, IP, MAC)…'), onDeviceSelect);
		if (savedIp && savedIp !== '__all__') {
			var matchDev = devices.filter(function(d) { return d.ip === savedIp; })[0];
			searchSelect.setValue(savedIp, matchDev ? matchDev.name + '  —  ' + matchDev.ip : savedIp);
		}

		// Back/forward between devices. updateUrlParams() only pushes when the
		// device changes, and by the time runQuery() re-runs the URL already
		// matches, so this cannot push another entry and loop.
		self._onPopState = function() {
			var urlIp = new URLSearchParams(window.location.search).get('ip') || '__all__';
			if (searchSelect.getValue() === urlIp) return;
			var o = loadOpts(); o.lastIp = urlIp; saveOpts(o);
			var dev = (self._lastRows || []).filter(function(d) { return d.ip === urlIp; })[0];
			searchSelect.setValue(urlIp, urlIp === '__all__' ? '' : (dev ? dev.name + '  —  ' + dev.ip : urlIp));
			updateModeUI();
			runQuery();
		};
		window.addEventListener('popstate', self._onPopState);

		// 【本仓库改动 v0.6.9】「最近设备」chip 行已移除（用户框选要求删除）。
		//   allBtn 保留，并改挂到 picker 行的搜索框**左侧**。
		//   renderRecentChips 仍保留 —— addRecentDevice 依旧在记录访问历史，
		//   只是不再有地方展示它（将来若要恢复，函数与存储都还在）。
		var allBtn = E('span', {'class':'cbi-button cbi-button-action'}, ['📊 ', _('All devices')]);
		allBtn.addEventListener('click', function() {
			searchSelect.setValue('__all__', '');
			onDeviceSelect('__all__');
		});

		function renderRecentChips() {
			// Update All button style
			// cbi-button cbi-button-action has the active (filled) look by default;
			// when a device is selected we switch to outline-only variant
			var currentIp = searchSelect.getValue();
			allBtn.className = currentIp === '__all__' ? 'cbi-button cbi-button-action' : 'cbi-button cbi-button-action cbi-button-action';
		}
		renderRecentChips();

		// 【本仓库改动】控件实现在 trafficctl/common.js，这里只做转发，
		// 保证设备页与设置页用的是同一套壳与同一套类名。
		var mkToggle   = T.mkToggle;
		var mkLabel    = T.mkLabel;
		var mkChipPick = T.mkChipPick;

		// 【本仓库改动 v0.6.9】「统计 / 连接 / 活动日志」三个开关已移除，三者**恒开**。
		//   它们此前是滑动开关，但三个都是「关掉就少看一块信息」——用户实测
		//   从不关它们，留着只是让人每次先确认一遍状态。开关行现在只剩
		//   「扩展统计」与「反向DNS」两项（它们是真会改变第序读取行为）。
		//   随之作废 showStats / showConns / showActivity 三个选项。
		var rdnsCheck = mkToggle('tm-rdns', _('rDNS'), opts.rdns, function() {
			var o = loadOpts(); o.rdns = this.checked; saveOpts(o); updateUrlParams(o);
		});
		var extStatsCheck = mkToggle('tm-extended', _('Extended'), opts.extendedStats, function() {
			var o = loadOpts(); o.extendedStats = this.checked; saveOpts(o); updateUrlParams(o);
			extStatsDiv.classList.toggle('tc-hidden', !this.checked);
			if (this.checked) updateExtendedStats();
		});

		// 【本仓库改动 v0.6.7】统计条（活跃 / 已阻断 / WiFi）与上联概览合成**一张卡片**。
		//   此前它们是两块：概览卡片（下载/上传/图表/接口/排行）下面另起一行窄条，
		//   两者底部与表格之间又各占一段间距，视觉上是三块互不相干的东西，
		//   而它们说的其实是同一件事（此刻网络的整体状况）。
		//   注意两个开关是**独立**的（统计 / 概览），故卡片只是外壳，两个子块
		//   各自显隐；卡片的可见性由「是否还有至少一个子块可见」决定 ——
		//   否则会出现「只剩一个空边框」或「关掉概览连带关掉统计条」。
		var extStatsDiv = E('div', { 'class': opts.extendedStats ? '' : 'tc-hidden' });
		var deviceGraphDiv = E('div', { 'class': 'tc-device-graph tc-hidden' });
		// 恒显（v0.6.9）：这三个容器不再带 tc-hidden。
		//   activityDiv 的内容要主动加载一次 —— 原先靠「活动日志」开关勾选时
		//   才调 loadActivityPanel，开关没了就必须在首屏自己触发。
		var activityDiv = E('div', {});

		// 【本仓库改动】刷新或轮询/窗口/算法这些**配置**项已整体移入设置页
		// （settings.js 的「表格与速率」卡片）。此前它们在这里各有一个副本，
		// 同一档位在两页显示不同默认值，正是「重复且混乱」的来源。
		// 本页只保留「影响本页显示」的开关，见下方视图开关行。

		var protoPick = mkChipPick([
			{v:'all',l:_('All')},{v:'tcp',l:'TCP'},{v:'udp',l:'UDP'}
		], opts.proto||'all', function(v) {
			var o = loadOpts(); o.proto = v; saveOpts(o);
		});

		var groupPick = mkChipPick(
			GROUP_OPTS, opts.groupBy||'none', function(v) {
			var o = loadOpts(); o.groupBy = v; saveOpts(o); runQuery();
		});

		var statusDiv = E('div', { 'class': 'tc-hidden' });
		// 不写内联 margin：它属于概览卡片内的抬头行，边距由 CSS 统一给
		// （.tc-overview > .alert-message）。内联样式的优先级高于样式表，
		// 留在这里会把卡片内的间距改坏。
		var statsDiv  = E('div', {});
		var connsDiv  = E('div', {});

		// 【本仓库改动 v0.6.7】统计条（活跃 / 已阻断 / WiFi）与上联概览合成**一张卡片**。
		//   此前它们是两块：概览卡片（下载/上传/图表/接口/排行）下面另起一行窄条，
		//   两者底部与表格之间又各占一段间距，视觉上是三块互不相干的东西，
		//   而它们说的其实是同一件事（此刻网络的整体状况）。
		//   两个子块是**独立**的（统计条有自己的开关；概览自 v0.6.8 起常显，
		//   只在「所有设备」模式下出现），故卡片只是外壳，两个子块各自显隐；
		//   卡片的可见性由「至少一个子块可见」决定 —— 否则会出现「只剩一个空边框」
		//   或「关掉统计连带关掉概览」。
		//   注意定义顺序：statsDiv 必须**先**定义，否则 var 提升会让这里拿到
		//   undefined，E(...) 的 children 里出现 undefined → 整页空白。
		var overviewDiv = E('div', { 'class': 'tc-ov-body' });
		var overviewCard = E('div', { 'class': 'tc-overview tc-hidden' }, [statsDiv, overviewDiv]);

		// 卡片的可见性：两个子块里**至少一个有内容且未被关掉**。
		//   判据用 firstChild 而不只是 tc-hidden —— 子块在首帧都是空的
		//   （统计条要等 runSummary 第一次回来才填），只看 tc-hidden 会让
		//   卡片画出一个空的边框。
		function updateOverviewCard() {
			var anyVisible =
				(!statsDiv.classList.contains('tc-hidden') && !!statsDiv.firstChild) ||
				(!overviewDiv.classList.contains('tc-hidden') && !!overviewDiv.firstChild);
			overviewCard.classList.toggle('tc-hidden', !anyVisible);
		}

		// ── 表格与速率 ────────────────────────────────────────────────────
		// 【本仓库改动】这组档位原在设置页（settings.js 的「表格与速率」卡片）。
		//   它决定的就是**下面这张设备表**怎么刷新、速率按什么窗口/算法算 ——
		//   放在设备表上方，改完立刻能看到效果；放在设置页则要来回切 tab 才知道
		//   有没有生效。故整体搬到此处。
		//
		//   注意各档位的副作用与设置页版本一致（不能只写 localStorage 就完事）：
		//     poll    → 重启采样定时器（_restartBytesPoll）
		//     window  → 立即按新窗口重算重绘（refreshSpeedViews）
		//     method  → 清空历史与两个 EWMA 累加器后重算
		//     refresh → 重设定时器；从「关」切回非 0 时立刻拉一次
		var pollIntervalPick = mkChipPick([
			{v:'0',l:_('Off')},{v:'1',l:'1s'},{v:'2',l:'2s'},{v:'5',l:'5s'},
			{v:'10',l:'10s'},{v:'30',l:'30s'}
		], String(optPoll(opts)), function(v) {
			var o = loadOpts(); o.pollInterval = parseInt(v, 10); saveOpts(o); updateUrlParams(o);
			self._restartBytesPoll();
		});

		var avgWindowPick = mkChipPick([
			{v:'5',l:'5s'},{v:'15',l:'15s'},{v:'30',l:'30s'},{v:'60',l:'60s'},
			{v:'120',l:'2m'},{v:'300',l:'5m'}
		], String(optWindow(opts)), function(v) {
			var o = loadOpts(); o.avgWindow = parseInt(v, 10); saveOpts(o); updateUrlParams(o);
			refreshSpeedViews();
		});

		var avgMethodPick = mkChipPick([
			{v:'simple',l:_('Simple')},{v:'ewma',l:_('EWMA')}
		], opts.avgMethod || 'simple', function(v) {
			var o = loadOpts(); o.avgMethod = v; saveOpts(o); updateUrlParams(o);
			// 切换算法后必须清掉历史与两个 EWMA 累加器，否则两种算法的数据
			// 互相污染。上下行存在同一个 _speedHistory（每条 {speed,up,time}），
			// 故不存在单独的 _speedHistoryUp。
			self._speedHistory = {};
			self._speedEwma = {}; self._speedEwmaUp = {};
			refreshSpeedViews();
		});

		var refreshPick = mkChipPick([
			{v:'0',l:_('Off')},{v:'1',l:'1s'},{v:'2',l:'2s'},{v:'5',l:'5s'},
			{v:'10',l:'10s'},{v:'30',l:'30s'},{v:'60',l:'60s'}
		], String(optRefresh(opts)), function(v) {
			var o = loadOpts(); o.refresh = parseInt(v, 10); saveOpts(o); updateUrlParams(o);
			self._setupTimer();
			if (optRefresh(o) > 0) runQuery();
		});

		// 把当前 Poll / Window / Refresh 写为路由器默认值：让没配过的浏览器
		// 从这里起步，而不是逐个浏览器各设一遍。
		var defaultsStatus = E('span', {'class':'tc-save-status'});
		var defaultsBtn = E('button', {
			'class': 'tc-btn',
			'data-tip': _('Store the current Poll, Window and Refresh as this router\'s defaults, for browsers that have not set their own')
		}, _('Save as router default'));
		defaultsBtn.addEventListener('click', function() {
			var o = loadOpts();
			var poll = optPoll(o), win = optWindow(o), refr = optRefresh(o);
			defaultsBtn.disabled = true;
			defaultsStatus.textContent = _('Saving…');
			defaultsStatus.style.color = 'var(--tc-muted)';
			// 参数顺序须与 config_set 的 params 一致
			callConfigSet(null, null, null, null, poll, win, refr).then(function(res) {
				var ok = res && res.ok;
				defaultsStatus.textContent = ok ? '✓' : ('✗ ' + ((res && res.msg) || ''));
				defaultsStatus.style.color = ok ? 'var(--tc-ok)' : 'var(--tc-err)';
				if (ok) {
					siteDefaults.pollInterval = poll;
					siteDefaults.avgWindow = win;
					siteDefaults.refreshInterval = refr;
				}
				defaultsBtn.disabled = false;
			}).catch(function(e) {
				defaultsStatus.textContent = '✗ ' + e.message;
				defaultsStatus.style.color = 'var(--tc-err)';
				defaultsBtn.disabled = false;
			});
		});

		// 【本仓库改动】把「一个按钮 + 一个浮层面板」抽成工厂，供**两个**菜单复用：
		//   ① ☰ 档位（轮询/窗口/方法/刷新）② 「可见列」（设备列 / 连接表列 / 筛选）。
		//   两者的交互完全一致（点开、点别处关、Esc 关、面板内点击不关），
		//   复制一份必然漂移 —— 例如只有一边记住摘监听器。
		//   返回 { bar, panel, btn, setOpen, isOpen }：
		//     bar   —— 按钮 + 面板的容器（挂进按钮组）
		//     panel —— 面板本体（调用方往里塞内容）
		var popupMenus = [];
		function mkPopupMenu(opts) {
			var panel = E('div', {'class':'tc-menu-panel tc-hidden'});
			var btn = E('button', {
				'class': 'tc-menu-btn' + (opts.text ? ' tc-menu-btn--text' : ''),
				'type': 'button',
				'aria-haspopup': 'true',
				'aria-expanded': 'false',
				'data-tip': opts.tip || undefined
			}, opts.text || '☰');
			var bar = E('div', {'class':'tc-menu'}, [btn, panel]);
			var api = { bar: bar, panel: panel, btn: btn };

			api.setOpen = function(open) {
				panel.classList.toggle('tc-hidden', !open);
				btn.classList.toggle('tc-menu-btn--open', !!open);
				btn.setAttribute('aria-expanded', open ? 'true' : 'false');
				// 同一时刻只允许一个面板开着：两个浮层都贴着同一个按钮组，
				// 同时展开会互相盖住。
				if (open) {
					popupMenus.forEach(function(m) { if (m !== api) m.setOpen(false); });
				}
			};
			api.isOpen = function() { return !panel.classList.contains('tc-hidden'); };

			btn.addEventListener('click', function(ev) {
				ev.stopPropagation();
				api.setOpen(!api.isOpen());
			});
			// 面板内部的点击不冒泡到 document，否则点档位/列开关就会立刻关掉面板。
			panel.addEventListener('click', function(ev) { ev.stopPropagation(); });
			popupMenus.push(api);
			return api;
		}

		var speedMenu = mkPopupMenu({
			tip: _('Polling interval, averaging window and method, and table refresh')
		});
		var speedMenuPanel = speedMenu.panel;

		// 点页面别处 / 按 Esc 关闭**全部**面板。都不持久化「关闭」状态 ——
		// 它只是本次交互的浮层，不是一项配置。
		// 监听器必须具名挂到实例上，否则离开本页时无法摘除：页面视图切换后
		// 它们仍会收到点击，闭包里抓着已被移除的 DOM（内存泄漏 + 每次进页
		// 都多一层监听）。摘除在 handleTeardown 里做。
		function closeAllMenus() { popupMenus.forEach(function(m) { m.setOpen(false); }); }
		self._speedMenuDocClick = closeAllMenus;
		self._speedMenuDocKey = function(ev) { if (ev.key === 'Escape') closeAllMenus(); };
		document.addEventListener('click', self._speedMenuDocClick);
		document.addEventListener('keydown', self._speedMenuDocKey);

		// ☰ 面板内容：4 组档位 + 保存为路由器默认值。
		// 「保存」放在面板底部：它作用的正是这四个值，单独留在外面会变成一个
		// 悬空的按钮。
		function menuRow(tipText, label, pick) {
			return E('div', {'class':'tc-menu__row', 'data-tip': tipText},
				[mkLabel(label + ':'), pick.el]);
		}
		speedMenuPanel.appendChild(E('div', {}, [
			menuRow(_('How often live data is polled: speeds, graphs, drop/backlog counters, and the connection table in device view'),
				_('Poll'), pollIntervalPick),
			menuRow(_('Time window for speed averaging'), _('Window'), avgWindowPick),
			menuRow(_('Simple = arithmetic mean, EWMA = exponential weighted moving average'),
				_('Method'), avgMethodPick),
			menuRow(_('Auto-refresh interval for the device table'), _('Refresh'), refreshPick),
			E('div', {'class':'tc-menu__foot'}, [defaultsBtn, defaultsStatus])
		]));

		function _rdnsBatch(addrs, gen) {
			if (!addrs.length) return;
			callNetworkRrdnsLookup(addrs, 5000, addrs.length).then(function(replies) {
				if (gen !== self._queryGen) return;
				addrs.forEach(function(dst) {
					var host = (replies && replies[dst]) || null;
					self._rdnsCache[dst] = host;
					Array.prototype.forEach.call(
						connsDiv.querySelectorAll('[data-dst="'+dst+'"]'),
						function(cell) {
							if (host) { cell.textContent = host; cell.style.color = ''; }
							else { cell.innerHTML = '<span class="tc-c-faint">—</span>'; }
						}
					);
				});
			}).catch(function() {
				if (gen !== self._queryGen) return;
				addrs.forEach(function(dst) {
					self._rdnsCache[dst] = null;
					Array.prototype.forEach.call(
						connsDiv.querySelectorAll('[data-dst="'+dst+'"]'),
						function(cell) { cell.innerHTML = '<span class="tc-c-faint">—</span>'; }
					);
				});
			});
		}

		// Speed graph popup on spark cell hover
		var graphPopup = E('div', {'class':'tc-graph-popup tc-hidden'});
		document.body.appendChild(graphPopup);
		self._graphPopup = graphPopup;
		var graphPopupIp = null;
		var graphPopupTimer = null;

		function showGraphPopup(cell) {
			var ip = cell.getAttribute('data-spark-ip');
			if (!ip) return;
			graphPopupIp = ip;
			updateGraphPopup();
			var rect = cell.getBoundingClientRect();
			graphPopup.style.left = Math.max(8, rect.left - 160) + 'px';
			graphPopup.style.top = (rect.bottom + 6) + 'px';
			graphPopup.classList.remove('tc-hidden');
			if (!graphPopupTimer) {
				graphPopupTimer = setInterval(updateGraphPopup, 2000);
				self._graphPopupTimer = graphPopupTimer;
			}
		}
		function updateGraphPopup() {
			if (!graphPopupIp) return;
			var hist = self._fullHistory[graphPopupIp];
			var sm = self._shapeMap[graphPopupIp], dm = self._dropMap[graphPopupIp];
			var lk = (sm && sm.rate_kbit > 0) ? sm.rate_kbit : ((dm && dm.rate_kbit > 0) ? dm.rate_kbit : 0);
			// Fallback: get limit from summary rows if shapeMap not yet populated
			if (!lk && self._lastRows) {
				var row = self._lastRows.filter(function(r) { return r.ip === graphPopupIp; })[0];
				if (row) lk = (row.shape_kbit || 0) > 0 ? row.shape_kbit : (row.rate_limit_kbit || 0);
			}
			while (graphPopup.firstChild) graphPopup.removeChild(graphPopup.firstChild);
			var svg = renderFullGraph(hist, lk, 440, 200);
			if (svg) {
				graphPopup.appendChild(svg);
				if (lk > 0) {
					graphPopup.appendChild(E('div', {'class':'tc-graph-popup__note'},
						_('Note: speed is measured before shaper — bursts above limit are normal')));
				}
			} else {
				graphPopup.appendChild(E('span', {'class':'tc-graph-popup__empty'}, _('Not enough data yet')));
			}
		}
		function hideGraphPopup() {
			graphPopup.classList.add('tc-hidden');
			graphPopupIp = null;
			if (graphPopupTimer) { clearInterval(graphPopupTimer); graphPopupTimer = null; self._graphPopupTimer = null; }
		}

		graphPopup.addEventListener('mouseleave', hideGraphPopup);

		connsDiv.addEventListener('mouseenter', function(ev) {
			var cell = ev.target.closest ? ev.target.closest('[data-spark-ip]') : null;
			if (cell) showGraphPopup(cell);
		}, true);
		connsDiv.addEventListener('mouseleave', function(ev) {
			var cell = ev.target.closest ? ev.target.closest('[data-spark-ip]') : null;
			if (!cell) return;
			var related = ev.relatedTarget;
			if (related && (graphPopup === related || graphPopup.contains(related))) return;
			hideGraphPopup();
		}, true);

		var inetBtn = E('button', { 'class': 'cbi-button' }, '');
		var wifiBtn = E('button', { 'class': 'cbi-button tc-hidden' }, '');

		function updateInetBtn(blocked) {
			if (blocked) {
				inetBtn.textContent = _('Unblock Internet');
				inetBtn.className = 'cbi-button cbi-button-positive';
				inetBtn._action = 'unblock';
			} else {
				inetBtn.textContent = _('Block Internet');
				inetBtn.className = 'cbi-button cbi-button-negative';
				inetBtn._action = 'block';
			}
		}
		updateInetBtn(false);

		function updateWifiBtn(wifiBlocked, hasMac) {
			if (!hasMac) { wifiBtn.classList.add('tc-hidden'); return; }
			wifiBtn.classList.remove('tc-hidden');
			wifiBtn.disabled = false;
			if (wifiBlocked) {
				wifiBtn.textContent = _('Unblock WiFi');
				wifiBtn.className = 'cbi-button cbi-button-positive';
				wifiBtn._wifiAction = 'unblock';
			} else {
				wifiBtn.textContent = _('Block WiFi');
				wifiBtn.className = 'cbi-button cbi-button-negative';
				wifiBtn._wifiAction = 'block';
			}
		}

		// ── 限速部件（v0.6.9 起挂在行内「限制」弹层里）──────────────────────
		//
		// 【本仓库改动 v0.6.9】这些部件原先平铺在速率限制卡片里（一条常驻的
		//   速率档位行 + 目标/共享/网段），占掉卡片大半高度，而它们只在
		//   **要给某台设备设限速**时才用得上。现整体移进设备表「限制」链接
		//   打开的弹层：点哪台设备的限制，就在那台设备旁边设它的速率。
		//   部件本身（preset chip / 自定义输入 / Shaper-Limiter）实现未变，
		//   故切换逻辑与错误处理仍是原来那套。
		var _rateSelected = '0';
		// Set while the user has the custom field open. The per-device poll
		// re-syncs this panel from the device's current rate, and without this
		// it would close the field (and overwrite what is being typed) a few
		// seconds after it was opened.
		var _customPinned = false;
		var _modeSelected = 'shaper';

		var rateChipsRow = E('div', {'class':'tc-chips-row'});
		var rateChips = [];
		RATE_PRESETS.filter(function(p) { return p.v !== 'custom'; }).forEach(function(preset) {
			var chip = E('span', {'class': preset.v === '0' ? 'tc-chip tc-chip' : 'tc-chip'}, preset.l);
			chip._val = preset.v;
			chip.addEventListener('click', function() {
				_rateSelected = preset.v;
				updateRateChips();
				_customPinned = false;
				customRow.classList.add('tc-hidden');
				applyLimit();
			});
			rateChips.push(chip);
			rateChipsRow.appendChild(chip);
		});

		function updateRateChips() {
			rateChips.forEach(function(c) {
				if (c._val === '0') {
					c.className = c._val === _rateSelected ? 'tc-chip tc-chip--active' : 'tc-chip tc-chip';
				} else {
					c.className = c._val === _rateSelected ? 'tc-chip tc-chip--active' : 'tc-chip';
				}
			});
			if (_rateSelected === 'custom') {
				rateChips.forEach(function(c) { c.className = c._val === '0' ? 'tc-chip tc-chip' : 'tc-chip'; });
			}
		}

		// Custom input row
		var customInput = E('input', { 'type':'number', 'min':'1', 'step':'1', 'placeholder': _('value'),
			'class': 'tc-custom-input' });
		var customUnitBtns = E('span', {'class':'tc-custom-unit-btns'});
		var _customUnit = 'mbit';
		var mbitBtn = E('span', {'style':'padding:4px 8px;font-size:11px;cursor:pointer;background:var(--tc-speed);color:#fff'}, 'Mbit/s');
		var kbitBtn = E('span', {'style':'padding:4px 8px;font-size:11px;cursor:pointer;background:var(--tc-bg);color:currentColor'}, 'kbit/s');
		function updateUnitBtns() {
			mbitBtn.style.background = _customUnit === 'mbit' ? 'var(--tc-speed)' : 'var(--tc-bg)';
			mbitBtn.style.color = _customUnit === 'mbit' ? '#fff' : 'currentColor';
			kbitBtn.style.background = _customUnit === 'kbit' ? 'var(--tc-speed)' : 'var(--tc-bg)';
			kbitBtn.style.color = _customUnit === 'kbit' ? '#fff' : 'currentColor';
		}
		mbitBtn.addEventListener('click', function() { _customUnit = 'mbit'; updateUnitBtns(); });
		kbitBtn.addEventListener('click', function() { _customUnit = 'kbit'; updateUnitBtns(); });
		customUnitBtns.appendChild(mbitBtn);
		customUnitBtns.appendChild(kbitBtn);

		var customApplyBtn = E('button', {
			'class':'cbi-button cbi-button-action'
		}, _('Apply'));
		customApplyBtn.addEventListener('click', function() {
			_rateSelected = 'custom';
			updateRateChips();
			_customPinned = false;
			applyLimit();
		});

		var customToggleBtn = E('span', {'class': 'tc-chip', 'data-tip': _('Enter a custom speed value')}, '✎ ' + _('Custom'));
		customToggleBtn.addEventListener('click', function() {
			customRow.classList.toggle('tc-hidden');
			_customPinned = !customRow.classList.contains('tc-hidden');
			if (_customPinned) customInput.focus();
		});
		rateChipsRow.appendChild(customToggleBtn);

		var customRow = E('div', {'class':'tc-custom-row tc-hidden'}, [
			customInput, customUnitBtns, customApplyBtn
		]);

		// ── Separate upload ceiling ────────────────────────────────────────
		//
		// Disclosed rather than always shown. Most limits are symmetric, and
		// the backend treats an absent upload rate as "same as download", so
		// the default state of this control matches the default meaning: one
		// number, one click. Opening it is the opt-in into two.
		//
		// The rate chips above stay the DOWNLOAD ceiling in either state, so
		// the common path does not change shape when this is revealed.
		var upInput = E('input', { 'type':'number', 'min':'1', 'step':'1',
			'placeholder': _('value'), 'class': 'tc-custom-input' });
		var _upUnit = 'mbit';
		var upMbitBtn = E('span', {'class':'tc-unit-btn'}, _('Mbit/s'));
		var upKbitBtn = E('span', {'class':'tc-unit-btn'}, _('kbit/s'));
		function updateUpUnitBtns() {
			upMbitBtn.classList.toggle('tc-unit-btn--on', _upUnit === 'mbit');
			upKbitBtn.classList.toggle('tc-unit-btn--on', _upUnit === 'kbit');
		}
		upMbitBtn.addEventListener('click', function() { _upUnit = 'mbit'; updateUpUnitBtns(); });
		upKbitBtn.addEventListener('click', function() { _upUnit = 'kbit'; updateUpUnitBtns(); });
		updateUpUnitBtns();

		var upRow = E('div', {'class':'tc-custom-row tc-hidden'}, [
			E('span', {'class':'tc-c-muted','style':'font-size:11px'}, _('↑ Upload')),
			upInput,
			E('span', {'class':'tc-custom-unit-btns'}, [upMbitBtn, upKbitBtn])
		]);

		var upToggleBtn = E('span', {'class': 'tc-chip',
			'data-tip': _('Give upload its own ceiling instead of matching download')
		}, '⇅ ' + _('Split up/down'));
		upToggleBtn.addEventListener('click', function() {
			upRow.classList.toggle('tc-hidden');
			var on = !upRow.classList.contains('tc-hidden');
			upToggleBtn.classList.toggle('tc-chip--active', on);
			if (on) { upInput.focus(); } else { upInput.value = ''; }
		});
		rateChipsRow.appendChild(upToggleBtn);

		// Mode: segmented toggle (Shaper default)
		var modeToggle = E('div', {'class':'tc-mode-toggle'});
		var shaperBtn = E('span', {
			'style':'padding:5px 12px;font-size:11px;font-weight:600;cursor:pointer;transition:all .15s',
			'data-tip': _('Queues excess traffic (smoother streaming, lower jitter)')
		}, _('Shaper'));
		var limiterBtn = E('span', {
			'style':'padding:5px 12px;font-size:11px;font-weight:500;cursor:pointer;transition:all .15s',
			'data-tip': _('Drops excess packets (instant enforcement, low overhead)')
		}, _('Limiter'));
		function updateModeToggle() {
			shaperBtn.style.background = _modeSelected === 'shaper' ? 'var(--tc-speed)' : 'var(--tc-bg)';
			shaperBtn.style.color = _modeSelected === 'shaper' ? '#fff' : 'currentColor';
			shaperBtn.style.fontWeight = _modeSelected === 'shaper' ? '600' : '500';
			limiterBtn.style.background = _modeSelected === 'limiter' ? 'var(--tc-warn)' : 'var(--tc-bg)';
			limiterBtn.style.color = _modeSelected === 'limiter' ? '#fff' : 'currentColor';
			limiterBtn.style.fontWeight = _modeSelected === 'limiter' ? '600' : '500';
		}
		shaperBtn.addEventListener('click', function() { _modeSelected = 'shaper'; updateModeToggle(); });
		limiterBtn.addEventListener('click', function() { _modeSelected = 'limiter'; updateModeToggle(); });
		modeToggle.appendChild(shaperBtn);
		modeToggle.appendChild(limiterBtn);
		updateModeToggle();

		// 【本仓库改动 v0.6.9】「目标 / 共享 / 网段」整组已移除（用户框选要求删除）。
		//   限速的目标不再是「在卡片里填一个 CIDR」，而是**点哪台设备的「限制」
		//   就在那台设备上施加**（见 mkLimitPopup）。故这一整段失去挂载点：
		//   `_scopeSelected` / `_monitoredSubnets` / `scopeInput` / `subnetChips`
		//   / `scopeChips` / `scopeExplain` / `scopeWarn` / `targetIsMonitored`
		//   / `updateScopeExplain` / `callSubnets()` 全部删除。
		//
		//   注意**保留**「已有的网段限制」列表（subnetLimitsBox）—— 它不在被删的
		//   范围内，而且是既有全局限速**唯一**可见、可删的地方。删掉它会让此前
		//   设过全网/网段限速的人再也去不掉那条规则。

		// ── Active subnet limits ──────────────────────────────────────
		//
		// An aggregate limit has no row in the device table — it is not
		// attached to a device — so without this it was invisible once set and
		// could only be removed by retyping the exact same target. It sits in
		// the panel that creates it rather than in Settings: a rule that drops
		// packets for a whole VLAN should be in front of whoever opens the
		// page, not two clicks deep in a collapsed section.
		var subnetLimitsBox = E('div', {'class':'tc-subnet-limits tc-hidden'});

		function removeSubnetLimit(target, mode, btn) {
			btn.disabled = true;
			setStatus(statusDiv, 'loading', _('Removing limit on') + ' ' + target + '…');
			callRatelimit(target, 0, '', mode).then(function(res) {
				setStatus(statusDiv, (res && res.ok) ? 'ok' : 'error',
					(res && res.msg) || _('Throttle removed'));
				pollDrops();
			}).catch(function(e) {
				btn.disabled = false;
				setStatus(statusDiv, 'error', '✗ ' + e.message);
			});
		}

		function renderSubnetLimits() {
			var limits = self._subnetLimits || [];
			subnetLimitsBox.classList.toggle('tc-hidden', !limits.length || !isAllMode());
			while (subnetLimitsBox.firstChild) {
				subnetLimitsBox.removeChild(subnetLimitsBox.firstChild);
			}
			if (!limits.length) { return; }

			subnetLimitsBox.appendChild(E('div', {'class':'tc-subnet-limits__title'},
				_('Active subnet limits')));
			limits.forEach(function(l) {
				var isShared = l.mode === 'shared';
				var target = (l.ip === '0.0.0.0/0') ? _('Whole network') : l.ip;
				var removeBtn = E('button', {'class':'cbi-button cbi-button-remove'}, _('Remove'));
				removeBtn.addEventListener('click', function() {
					removeSubnetLimit(l.ip, l.mode, removeBtn);
				});
				subnetLimitsBox.appendChild(E('div', {'class':'tc-subnet-limits__row'}, [
					E('span', {'class':'tc-mono tc-subnet-limits__target'}, target),
					E('span', {'class':'tc-mono tc-c-speed'}, fmtRate(l.rate_kbit)),
					E('span', {
						'class': 'tc-subnet-limits__mode',
						'data-tip': isShared
							? _('One bucket for the whole subnet')
							: _('One bucket per device inside the subnet')
					}, isShared ? _('shared between them') : _('each')),
					E('span', {'class':'tc-c-muted tc-subnet-limits__drops'},
						l.packets > 0
							? (String(l.packets) + ' ' + _('packets dropped') + ' (' + fmtBytes(l.bytes) + ')')
							: _('nothing dropped yet')),
					removeBtn
				]));
			});
		}

		// 【本仓库改动 v0.6.9】原先这里拉一次 callSubnets() 把「已监控网段」
		//   做成 chip，供用户在卡片里选作限速目标。目标选择已随「限制」入口
		//   移走 → 这批 chip 与它依赖的 addSubnetChip / updateSubnetChips /
		//   updateScopeExplain 一并删除。`callSubnets` 的 rpc 声明仍留在
		//   common.js（rpc 表是共用的，删它会影响设置页）。

		// 【本仓库改动】「切断全部互联网访问」原是一个与速率限制并列的独立卡片，
		//   两者都是「对设备/全网施加限制」，却分成两块、各占一行高度。现并入
		//   速率限制卡片下方，由 .tc-cut--embedded 去掉重复的外框与标题栏高度。
		//   注意：它必须仍然常显 —— 这是本应用唯一能把操作者自己关在门外的控件，
		//   不能藏进任何折叠区。故放在这个恒常可见的面板里，而不是设置页。
		//   定义提前到此处是因为要在构造 rateLimitRow 时就把它挂进去
		//   （var 提升对下方的 renderCut 等函数同样成立）。
		var cutPanel = E('div', {'class': 'tc-cut tc-cut--embedded'});

		// 【本仓库改动】设备选择（搜索框 + 「所有设备」+ 最近设备 chip）原先是
		//   速率限制面板**之上**的独立一行，与面板里的「目标」是两个各自成行的
		//   选择器 —— 用户要在这两处之间来回看。现整体并入速率限制面板，
		//   与「目标」同排成一行：左边选设备、右边设限制。
		//   注意 searchSelect / quickBar 在本文件上方（约 1731/1754 行）就已构造，
		//   此处只是把它们挂进面板，不新建实例 —— 否则事件绑定会全部失效。
		//
		// 【本仓库改动 v0.6.9】picker 行只剩两个控件，顺序为 **所有设备 | 搜索框**
		//   （用户指定：按钮在输入框左侧）。原先这一行还挤着最近设备 chip、
		//   目标、共享、网段四组 —— 全是「怎么施加限制」，与「选哪台设备」
		//   混在同一行，扫一眼分不出哪部分在选设备。
		//   限速目标随「限速」入口一并移到设备表的「限制」里（见 mkLimitPopup），
		//   故这里不再需要 scopeSlot。
		//
		//   「拦截互联网 / 拦截 WiFi」按钮（actionRow）在下方才构造，
		//   此处先留一个占位容器，稍后把按钮挂进来。**不能**直接引用 actionRow：
		//   var 提升会给出 undefined，且它会被当成文本节点渲染成页面上一个字面的
		//   "undefined"（实测踩过）。
		var actionSlot = E('div', {'class':'tc-picker-row__actions'});
		var pickerRow = E('div', {'class':'tc-picker-row'}, [
			E('div', {'class':'tc-picker-row__device'}, [allBtn, searchSelect.el]),
			actionSlot
		]);

		// 视图开关行与「可见列」菜单在文件下方才构造（依赖列 chip 等）。
		// 用一个占位容器在此先留好位置，稍后再把内容 append 进来 ——
		// 直接引用会因 var 提升拿到 undefined（赋值发生在下方）。
		var panelTail = E('div', {'class':'tc-rate-panel__tail'});

		// 【本仓库改动】不再带初始 tc-hidden。原因：切断面板（下面嵌进来的
		//   cutPanel）是**安全关键**控件 —— 它能把操作者自己关在门外，
		//   其状态必须在页面一渲染出来就可读。原先靠 updateModeUI() 里的
		//   `rateLimitRow.classList.remove('tc-hidden')` 才显示，即它依赖
		//   runQuery() 那条异步链；若该链因任何原因未走到（异常、RPC 挂起），
		//   整个面板连同切断开关一起消失 —— 对这一个控件来说是不可接受的失败模式。
		//   现在首屏即显示，updateModeUI 里那行 remove 保留作幂等兜底。
		// 【本仓库改动 v0.6.9】速率档位行（关 / 1Mbit … / 自定义 / 上下行分别设置）
		//   与 Shaper-Limiter 切换已移进设备表「限制」弹层（mkLimitPopup）。
		//   卡片本身保留：它仍是「选设备 + 切断全网访问 + 查看已有网段限制 +
		//   视图开关」的容器，且 cutPanel 必须常显（安全关键，见上）。
		var rateLimitRow = E('div', {
			'class': 'tc-rate-panel'
		}, [
			E('div', {'class':'tc-rate-panel__header'}, [
				E('span', {'class':'tc-rate-panel__title'}, _('Speed Limit'))
			]),
			pickerRow,
			subnetLimitsBox,
			cutPanel,
			panelTail
		]);

		// Compat shims for existing code that uses ratePick/modePick interface
		var ratePick = {
			getValue: function() { return _rateSelected; },
			setValue: function(v) { _rateSelected = v; updateRateChips(); },
			el: rateChipsRow
		};
		var modePick = {
			getValue: function() { return _modeSelected; },
			setValue: function(v) { _modeSelected = v; updateModeToggle(); },
			el: modeToggle
		};
		function getRateKbit() {
			if (_rateSelected !== 'custom') return _rateSelected;
			var n = parseFloat(customInput.value);
			if (!n || n <= 0) return '0';
			if (_customUnit === 'mbit') return String(Math.round(n * 1000));
			return String(Math.round(n));
		}

		// Empty string means symmetric — never 0, which the backend would have
		// to read as a ceiling and which is a total upload block.
		function getRateKbitUp() {
			if (upRow.classList.contains('tc-hidden')) return '';
			var n = parseFloat(upInput.value);
			if (!n || n <= 0) return '';
			return String(_upUnit === 'mbit' ? Math.round(n * 1000) : Math.round(n));
		}

		// How the pending action is described. Naming one figure when the
		// operator has entered two would hide the thing they just asked for.
		function rateLabel(kbit, up) {
			if (!up || up === kbit) return fmtRate(parseInt(kbit));
			return _('%s down / %s up').format(fmtRate(parseInt(kbit)), fmtRate(parseInt(up)));
		}

		// 【本仓库改动 v0.6.9】原来是 `applyRate()`，目标取自「所有设备」模式下的
		//   scopeInput / 单设备模式下的 searchSelect —— 即「先在卡片里选目标，
		//   再点速率」。现改为 `applyLimit()`：目标是**打开弹层的那台设备**
		//   （`_limitIp`，由 mkLimitPopup 设置）。这样：
		//     · 不再需要 scopeInput / _scopeSelected / all 模式分支；
		//     · 全局限速（网段/CIDR）不再从界面新建 —— 已有规则仍可在
		//       「已有的网段限制」列表里删除（renderSubnetLimits 保留）。
		var _limitIp = null;
		var _limitName = '';
		function applyLimit() {
			if (!_limitIp) return;
			var ip = _limitIp;
			var name = _limitName;
			var kbit = getRateKbit();
			var kbitUp = getRateKbitUp();
			var mode = _modeSelected;

			if (kbit === '0') {
				setStatus(statusDiv, 'loading', _('Removing throttle…'));
				Promise.all([
					callRatelimit(ip, 0, name),
					callShapeRemove(ip, name)
				]).then(function(results) {
					var res = results[0] || {};
					setStatus(statusDiv, 'ok', res.msg || _('Throttle removed'));
					runQuery();
				}).catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
			} else if (mode === 'shaper') {
				setStatus(statusDiv, 'loading', _('Shaping') + ' ' + ip + ' → ' + rateLabel(kbit, kbitUp) + '…');
				callRatelimit(ip, 0, name)
					.then(function() { return callShapeAdd(ip, parseInt(kbit), name, kbitUp ? parseInt(kbitUp) : null); })
					.then(function(res) {
						setStatus(statusDiv, (res && res.ok) ? 'action' : 'error', (res && res.msg) || '?');
						runQuery();
					})
					.catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
			} else {
				setStatus(statusDiv, 'loading', _('Limiting') + ' ' + ip + ' → ' + rateLabel(kbit, kbitUp) + '…');
				callShapeRemove(ip, name)
					.then(function() { return callRatelimit(ip, parseInt(kbit), name, '', kbitUp ? parseInt(kbitUp) : null); })
					.then(function(res) {
						setStatus(statusDiv, (res && res.ok) ? 'action' : 'error', (res && res.msg) || '?');
						runQuery();
					})
					.catch(function(e) { setStatus(statusDiv, 'error', '✗ '+e.message); });
			}
		}

		// 挂进速率限制面板里预留的位置（见上文 actionSlot 的说明）。
		var actionRow = E('div', { 'class': 'tc-action-row' },
			[inetBtn, wifiBtn]);
		actionSlot.appendChild(actionRow);

		// ── 行内「限制」弹层（v0.6.9）─────────────────────────────────────
		//
		// 点设备表操作列的「限制」，在这台设备旁边弹出它的限速设置：
		//   速率档位（关 / 1Mbit … / 自定义）＋ Shaper-Limiter 切换 ＋ 上下行分别设置。
		//   这一切原先平铺在「速率限制」卡片里，占掉大半高度，却只在**要给某台
		//   设备设限速**时才用得上；而设限速本来就要先选中一台设备 —— 两件事
		//   合成一步，点哪台就设哪台。
		//
		//   复用同一套部件实例（rateChipsRow / customRow / modeToggle），
		//   故切换逻辑与错误处理仍是原来那套，只是换了挂载点。
		var limitPopup = E('div', {'class':'tc-limit-popup tc-hidden'}, [
			E('div', {'class':'tc-limit-popup__who'}),
			rateChipsRow,
			customRow,
			upRow,
			E('div', {'class':'tc-limit-popup__foot'}, [
				E('span', {'class':'tc-inline-label'}, _('Mode:')),
				modeToggle
			])
		]);
		document.body.appendChild(limitPopup);
		self._limitPopup = limitPopup;
		var _limitPopupOpen = false;

		function openLimitPopup(cell, ip, name) {
			_limitIp = ip;
			_limitName = name || '';
			// 回填这台设备当前的限速值，使弹层一开就显示既有设置（而不是
			// 停在上一台设备的值）。_customPinned 置假，否则用户上次编辑过
			// 自定义值会阻止回填。
			_customPinned = false;
			var row = (self._lastRows || []).filter(function(r) { return r.ip === ip; })[0] || {};
			var shapeRate = row.shape_kbit || 0;
			var limitRate = row.rate_limit_kbit || 0;
			var curRate = shapeRate > 0 ? shapeRate : limitRate;
			var curStr = String(curRate);
			if (RATE_PRESETS.some(function(p) { return p.v === curStr; })) {
				_rateSelected = curStr;
				customRow.classList.add('tc-hidden');
			} else if (curRate > 0) {
				_rateSelected = 'custom';
				customInput.value = curRate;
				_customUnit = 'kbit'; updateUnitBtns();
				customRow.classList.remove('tc-hidden');
			} else {
				_rateSelected = '0';
				customRow.classList.add('tc-hidden');
			}
			updateRateChips();
			// 上行分栏默认收起（后端把「无上行速率」解释为与下行相同），
			// 并清掉上一台设备残留的值。
			upRow.classList.add('tc-hidden');
			upToggleBtn.classList.remove('tc-chip--active');
			upInput.value = '';
			_modeSelected = shapeRate > 0 ? 'shaper' : (limitRate > 0 ? 'limiter' : 'shaper');
			updateModeToggle();

			// 名称可能是后端占位（`*`）或空，那种情况下只显示 IP ——
			// 写成「*  —  192.168.3.203」看着像坏掉的数据。
			limitPopup.querySelector('.tc-limit-popup__who').textContent =
				(name && name !== '*') ? (name + '  —  ' + ip) : ip;
			var r = cell.getBoundingClientRect();
			// 先显示再量高度：弹层高度随内容（自定义/上行分栏是否展开）变化，
			// 用固定估值会算错位置。故先去 tc-hidden 拿到真实尺寸，再定位。
			limitPopup.classList.remove('tc-hidden');
			var pw = limitPopup.offsetWidth || 340;
			var ph = limitPopup.offsetHeight || 200;
			// 水平：贴住该行左侧，右边界收进视口内。
			limitPopup.style.left = Math.max(8, Math.min(r.left, window.innerWidth - pw - 8)) + 'px';
			// 垂直：优先在该行**下方**；下方放不下、而上方更宽裕时才翻到上方。
			//   此前只写 `min(r.bottom+4, innerHeight-40)` —— 实测弹层高 192px
			//   而当时只剩 40px，于是大半落在屏幕外（截图为证）。
			var below = window.innerHeight - r.bottom - 8;
			var above = r.top - 8;
			limitPopup.style.top = ((below >= ph || below >= above)
				? r.bottom + 4
				: Math.max(8, r.top - ph - 4)) + 'px';
			_limitPopupOpen = true;
		}
		function closeLimitPopup() {
			limitPopup.classList.add('tc-hidden');
			_limitPopupOpen = false;
			_limitIp = null;
		}
		// 点弹层内部不关（否则点速率档位就消失了）；监听器具名挂到实例。
		limitPopup.addEventListener('click', function(ev) { ev.stopPropagation(); });
		self._limitPopupDocClick = function() { if (_limitPopupOpen) closeLimitPopup(); };
		self._limitPopupDocKey = function(ev) { if (ev.key === 'Escape' && _limitPopupOpen) closeLimitPopup(); };
		document.addEventListener('click', self._limitPopupDocClick);
		document.addEventListener('keydown', self._limitPopupDocKey);

		function isAllMode() { return searchSelect.getValue() === '__all__'; }

		function updateModeUI() {
			var all = isAllMode();
			actionRow.classList.toggle('tc-hidden', all);
			// The throttle panel used to be hidden in all-devices mode, which
			// left no way to limit a subnet or the whole network at all.
			// 【本仓库改动】它现已首屏可见（见构造处的说明：其中嵌着安全关键的
			//   切断开关）。这行保留作幂等兜底，删掉也不影响首屏。
			rateLimitRow.classList.remove('tc-hidden');
			// 目标/共享/网段那一行已随「限制」入口移走；卡片里现在只剩
			// 「选设备 + 已有的网段限制 + 切断 + 视图开关」，都不随模式隐藏
			// （pickerRow 在单设备模式下也有用：它显示当前选中的设备）。
			renderSubnetLimits();
			rdnsCheck.classList.toggle('tc-hidden', all);
			extStatsCheck.classList.toggle('tc-hidden', all);
			// 概览是整台路由器的视图，只在「所有设备」模式下有意义。
			// v0.6.8 起它没有开关、常显，故这里只按模式显隐。
			overviewDiv.classList.toggle('tc-hidden', !all);
			extStatsDiv.classList.toggle('tc-hidden', all || !loadOpts().extendedStats);
			// 概览的显隐刚变过，卡片要跟着决定自己是否还有内容。
			updateOverviewCard();
			if (typeof updateTableSectionMode === 'function') updateTableSectionMode();
		}

		function updateSpeedCells() {
			var globalMax = 0;
			Object.keys(self._speedHistory).forEach(function(ip) {
				var hist = self._speedHistory[ip];
				if (hist) hist.forEach(function(h) { if (h.speed > globalMax) globalMax = h.speed; });
			});

			Object.keys(self._speedMap).forEach(function(ip) {
				var s = self._speedMap[ip];
				var cell = connsDiv.querySelector('[data-speed-ip="'+ip+'"]');
				if (!cell) return;
				// renderSpeedCell keeps the layout classes ('td tc-right tc-mono')
				// rather than assigning className outright, which is what used to
				// break this cell's alignment.
				renderSpeedCell(cell, s);
				cell.title = _('Avg')+': '+fmtSpeed(s.avg)+' / '+_('Max')+': '+fmtSpeed(s.max);

				var upCell = connsDiv.querySelector('[data-speed-up-ip="'+ip+'"]');
				if (upCell) {
					var up = s.current_up || 0;
					upCell.className = 'td tc-right tc-mono ' +
						(up > 1024 ? 'tc-speed-active' : 'tc-speed-idle');
					upCell.textContent = fmtSpeed(up);
					upCell.title = _('Avg')+': '+fmtSpeed(s.avg_up||0)+' / '+_('Max')+': '+fmtSpeed(s.max_up||0);
				}

				var sparkCell = connsDiv.querySelector('[data-spark-ip="'+ip+'"]');
				if (sparkCell) {
					while (sparkCell.firstChild) sparkCell.removeChild(sparkCell.firstChild);
					var sm = self._shapeMap[ip], dm = self._dropMap[ip];
					var lk = (sm && sm.rate_kbit > 0) ? sm.rate_kbit : ((dm && dm.rate_kbit > 0) ? dm.rate_kbit : 0);
					var svg = renderSparkline(self._speedHistory[ip], globalMax, 60, 20, lk);
					if (svg) sparkCell.appendChild(svg);
				}
			});

		}

		function pollDrops() {
			if (document.hidden) return;
			if (pollDropsInFlight) return;
			pollDropsInFlight = true;
			callRatelimitStats().then(function(data) {
				pollDropsInFlight = false;
				if (!Array.isArray(data)) return;
				// Rebuilt from every response rather than accumulated the way
				// _dropMap is: a limit that was just removed has to leave the
				// list on the next poll, not linger until a page reload.
				var subnetLimits = [];
				data.forEach(function(d) {
					self._dropMap[d.ip] = { packets: d.packets, bytes: d.bytes, rate_kbit: d.rate_kbit, mode: d.mode, pass_packets: d.pass_packets, pass_bytes: d.pass_bytes };
						if (isSubnetTarget(d.ip) && d.rate_kbit > 0) { subnetLimits.push(d); }
				});
				self._subnetLimits = subnetLimits;
				renderSubnetLimits();
				if (isAllMode()) {
					Object.keys(self._dropMap).forEach(function(ip) {
						var dp = self._dropMap[ip].packets || 0;
						var db = self._dropMap[ip].bytes   || 0;
						var cell = connsDiv.querySelector('[data-drop-ip="'+ip+'"]');
						if (!cell) return;
						while (cell.firstChild) cell.removeChild(cell.firstChild);
						if (dp > 0) {
							cell.appendChild(E('span', {
								'class': 'tc-c-err tc-fw-bold',
								'title': fmtBytes(db) + ' ' + _('dropped')
							}, String(dp)));
						} else {
							cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '—'));
						}
					});
				}
				updateExtendedStats();
			}).catch(function(){ pollDropsInFlight = false; });
		}

		function pollShapeStats() {
			if (document.hidden) return;
			if (pollShapeInFlight) return;
			pollShapeInFlight = true;
			callShapeStats().then(function(data) {
				pollShapeInFlight = false;
				if (!Array.isArray(data)) return;
				data.forEach(function(d) {
					self._shapeMap[d.ip] = {
						packets: d.packets, bytes: d.bytes, backlog: d.backlog, rate_kbit: d.rate_kbit,
						drops: d.drops, overlimits: d.overlimits, requeues: d.requeues,
						lended: d.lended, borrowed: d.borrowed, ecn_mark: d.ecn_mark,
						new_flows: d.new_flows, old_flows: d.old_flows,
						target_us: d.target_us, memory_used: d.memory_used
					};
				});
				if (isAllMode()) {
					Object.keys(self._shapeMap).forEach(function(ip) {
						var bl = self._shapeMap[ip].backlog || 0;
						var cell = connsDiv.querySelector('[data-backlog-ip="'+ip+'"]');
						if (!cell) return;
						while (cell.firstChild) cell.removeChild(cell.firstChild);
						if (bl > 0) {
							cell.appendChild(E('span', { 'class': 'tc-c-speed tc-fw-bold', 'title': _('Bytes queued in tc') }, fmtBytes(bl)));
						} else {
							cell.appendChild(E('span', { 'class': 'tc-c-faint' }, '—'));
						}
					});
				}
				updateExtendedStats();
			}).catch(function(){ pollShapeInFlight = false; });
		}

		// Global overview. Deliberately has NO timer of its own: it is driven
		// from pollBytes(), so it inherits the Poll chip, the document.hidden
		// check and the start/stop lifecycle for free. A private setInterval
		// here would ignore the Poll setting and would be one more thing to
		// remember to clear on teardown — the bug class this repo has shipped
		// before with the speed-graph popup.
		function pollIfaces() {
			if (!isAllMode()) return;
			callIfaces().then(function(list) {
				if (!Array.isArray(list)) return;
				var now = Date.now();
				self._ifMeta = list;

				var seen = {};
				list.forEach(function(itf) {
					seen[itf.dev] = true;
					var prev = self._ifBytes[itf.dev];
					if (prev) {
						var dt = (now - prev.time) / 1000;
						if (dt >= 0.5) {
							var dRx = itf.rx_bytes - prev.rx;
							var dTx = itf.tx_bytes - prev.tx;
							// An interface that went down and came back up
							// restarts its counters at zero; a negative delta is
							// that, not traffic.
							if (dRx < 0) dRx = 0;
							if (dTx < 0) dTx = 0;
							if (!self._ifHistory[itf.dev]) self._ifHistory[itf.dev] = [];
							var h = self._ifHistory[itf.dev];
							h.push({ speed: dRx / dt, up: dTx / dt, time: now });
							if (h.length > IFACE_HISTORY_MAX) h.splice(0, h.length - IFACE_HISTORY_MAX);
						}
					}
					self._ifBytes[itf.dev] = { rx: itf.rx_bytes, tx: itf.tx_bytes, time: now };
				});
				// Forget interfaces that disappeared (a tunnel torn down, a
				// modem unplugged) so their history cannot grow unbounded
				// across a long session.
				Object.keys(self._ifHistory).forEach(function(dev) {
					if (!seen[dev]) { delete self._ifHistory[dev]; delete self._ifBytes[dev]; }
				});

				renderOverview();
			}).catch(function(){});
		}

		function renderOverview() {
			if (!isAllMode()) return;
			var o = loadOpts();
			var nameByIp = {};
			(self._lastRows || []).forEach(function(r) { nameByIp[r.ip] = r.name; });
			// 图表要按容器实宽绘制。容器此刻可能还没布局完（首帧、tab 隐藏），
			// 那时 offsetWidth 为 0，退回 560；下一拍轮询会用真实宽度重画。
			var panel = buildOverviewPanel(
				self._ifMeta, self._ifHistory, self._speedMap, nameByIp,
				!!o.ovShowOther,
				function(next) {
					var oo = loadOpts(); oo.ovShowOther = next; saveOpts(oo);
					renderOverview();
				},
				optPoll(o) <= 0,
				overviewDiv.clientWidth
			);
			while (overviewDiv.firstChild) overviewDiv.removeChild(overviewDiv.firstChild);
			overviewDiv.appendChild(panel);
			updateOverviewCard();
		}

		// 窗口尺寸变了要按新宽度重画上联图：图宽是按容器实宽算的，不重画就会
		// 停在旧宽度（拉宽浏览器后右侧留白，缩窄后横向溢出）。
		// 只挂一次、只在宽度**真的变了**时重画 —— resize 事件在拖动窗口时
		// 每帧都触发，无条件重画会连带重建表格行，白白吃 CPU。
		// 监听器具名挂到实例，随 handleTeardown 摘除（与两个菜单监听器同理）。
		var _lastOvW = 0;
		self._onResize = function() {
			if (!isAllMode()) return;
			var w = overviewDiv.clientWidth;
			if (w && Math.abs(w - _lastOvW) >= 2) { _lastOvW = w; renderOverview(); }
		};
		window.addEventListener('resize', self._onResize);

		// 【本仓库改动】各字节轮询的防重入闸。
		//   与 _setupTimer 旁的 queryInFlight 同一用意：一旦档位可设 1 秒，而
		//   单次 RPC 实测 P50≈290ms、最坏 1877ms（conntrack 读取在设备多时变慢），
		//   `setInterval` 会在慢的那一拍还没回来时再发一次 —— 实测 1 秒档位下
		//   30 秒内出现 3 次重叠、最多 2 个并发。请求层层堆积会让 rpcd 不断 fork
		//   子脚本、路由器 load 飙升（AGENTS.md 红线 9 记的正是这个故障）。
		//   闸门按「每类请求各自一个」：dro 与 shape 是 5 秒固定间隔，互不影响。
		var pollBytesInFlight = false;
		var pollDropsInFlight = false;
		var pollShapeInFlight = false;

		function pollBytes() {
			if (document.hidden) return;
			if (pollBytesInFlight) return;   // 上一拍未回，跳过这一拍
			pollBytesInFlight = true;
			// Runs in BOTH modes: byte counters are per-device, and the device
			// view's speed graph is fed from this history. Only the summary-table
			// repaint below is all-devices-specific.
			callBytes().then(function(data) {
				pollBytesInFlight = false;
				if (!Array.isArray(data)) return;
				var now = Date.now();
				var o = loadOpts();
				var pollInterval = optPoll(o) || siteDefaults.pollInterval;
				var avgWindow = optWindow(o);
				var avgMethod = o.avgMethod || 'simple';
				var maxSamples = Math.max(2, Math.round(avgWindow / (pollInterval || 2)));

				var activeIps = {};
				data.forEach(function(d) { activeIps[d.ip] = true; });
				// The router keeps a device's total while it is idle, but the
				// table only lists devices with live flows, so the browser-side
				// copy is dropped with the rest of that device's state.
				Object.keys(self._totalsMap).forEach(function(ip) {
					if (!activeIps[ip]) {
						delete self._totalsMap[ip];
					}
				});
				Object.keys(self._speedHistory).forEach(function(ip) {
					if (!activeIps[ip]) {
						delete self._speedHistory[ip];
						delete self._fullHistory[ip];
						delete self._speedMap[ip];
						delete self._speedEwma[ip];
						delete self._speedEwmaUp[ip];
						delete self._bytesHistory[ip];
					}
				});

				data.forEach(function(d) {
					var prev = self._bytesHistory[d.ip];
					if (prev) {
						var dt = (now - prev.time) / 1000;
						if (dt < 0.5) return;
						var dIn = d.bytes_in - prev.bytes_in;
						var dOut = d.bytes_out - prev.bytes_out;
						// Counter reset or wrap — discard this sample
						if (dIn < 0) dIn = 0;
						if (dOut < 0) dOut = 0;
						var speed = dIn / dt;
						var speedUp = dOut / dt;
						// Spike filter: cap at link speed (1 Gbit/s = 125 MB/s)
						var MAX_BPS = 125000000;
						if (speed > MAX_BPS) speed = 0;
						if (speedUp > MAX_BPS) speedUp = 0;

						if (!self._fullHistory[d.ip]) self._fullHistory[d.ip] = [];
						var fh = self._fullHistory[d.ip];
						fh.push({speed: speed, up: speedUp, time: now});
						if (fh.length > FULL_HISTORY_MAX) fh.splice(0, fh.length - FULL_HISTORY_MAX);

						if (avgMethod === 'ewma') {
							var alpha = 2 / (maxSamples + 1);
							var prevEwma = self._speedEwma[d.ip] || 0;
							var ewma = alpha * speed + (1 - alpha) * prevEwma;
							self._speedEwma[d.ip] = ewma;
							var prevEwmaUp = self._speedEwmaUp[d.ip] || 0;
							var ewmaUp = alpha * speedUp + (1 - alpha) * prevEwmaUp;
							self._speedEwmaUp[d.ip] = ewmaUp;
							if (!self._speedHistory[d.ip]) self._speedHistory[d.ip] = [];
							self._speedHistory[d.ip].push({speed: speed, up: speedUp, time: now});
							if (self._speedHistory[d.ip].length > maxSamples) self._speedHistory[d.ip].shift();
							var max = 0, maxUp = 0;
							self._speedHistory[d.ip].forEach(function(h){
								if (h.speed > max) max = h.speed;
								if ((h.up || 0) > maxUp) maxUp = h.up;
							});
							self._speedMap[d.ip] = {
								current: speed,
								up: speedUp,
								avg: ewma,
								max: max,
								current_up: speedUp,
								avg_up: ewmaUp,
								max_up: maxUp
							};
						} else {
							if (!self._speedHistory[d.ip]) self._speedHistory[d.ip] = [];
							self._speedHistory[d.ip].push({speed: speed, up: speedUp, time: now});
							if (self._speedHistory[d.ip].length > maxSamples) self._speedHistory[d.ip].shift();
							var hist = self._speedHistory[d.ip];
							var sum = 0, sMax = 0, sumUp = 0, sMaxUp = 0;
							hist.forEach(function(h){
								sum += h.speed; if (h.speed > sMax) sMax = h.speed;
								sumUp += (h.up || 0); if ((h.up || 0) > sMaxUp) sMaxUp = h.up;
							});
							self._speedMap[d.ip] = {
								current: speed,
								up: speedUp,
								avg: sum / hist.length,
								max: sMax,
								current_up: speedUp,
								avg_up: sumUp / hist.length,
								max_up: sMaxUp
							};
						}
					}
					self._bytesHistory[d.ip] = {
						bytes_in: d.bytes_in,
						bytes_out: d.bytes_out,
						time: now
					};

					// Lifetime totals, accumulated by trafficctl-totals.sh.
					// The proto fields arrive as -1 when the router cannot
					// measure them (nft counters under flow offload), and that
					// -1 is carried through untouched so the cell can say so
					// instead of printing a zero nobody can explain.
					var tcpT = (d.bytes_tcp_total == null) ? -1 : Number(d.bytes_tcp_total);
					var udpT = (d.bytes_udp_total == null) ? -1 : Number(d.bytes_udp_total);
					var liveTcp = (d.bytes_tcp == null) ? -1 : Number(d.bytes_tcp);
					var liveUdp = (d.bytes_udp == null) ? -1 : Number(d.bytes_udp);
					self._totalsMap[d.ip] = {
						total: (Number(d.bytes_in_total) || 0) + (Number(d.bytes_out_total) || 0),
						tcp: tcpT,
						udp: udpT,
						liveTotal: (Number(d.bytes_in) || 0) + (Number(d.bytes_out) || 0),
						liveTcp: liveTcp,
						liveUdp: liveUdp,
						// 【本仓库改动】累计上行 / 下行分列（参照图的「累计上行」「累计下行」）。
						//   方向已核对：bytes_out = 设备上传、bytes_in = 设备下载。
						//   -1 保留语义与 TCP/UDP 一致（「不可测」不能与「0」同形）。
						up: (d.bytes_out_total == null) ? -1 : Number(d.bytes_out_total),
						dn: (d.bytes_in_total == null) ? -1 : Number(d.bytes_in_total),
						liveUp: (d.bytes_out == null) ? -1 : Number(d.bytes_out),
						liveDn: (d.bytes_in == null) ? -1 : Number(d.bytes_in),
						since: Number(d.total_since) || 0,
						degraded: (d.degraded === true)
					};
				});
				if (isAllMode()) {
					if (self._sumCol === '_speed') {
						runAll();
					} else {
						updateSpeedCells();
						updateTotalCells();
					}
				}
				updateDeviceGraph();
				// Same tick as the device counters, so the overview's "Top
				// talkers" and the summary table can never disagree about who
				// is busy.
				pollIfaces();
			}).catch(function(){
				// 出错也要解锁，否则一次失败会让轮询永久停摆。
				pollBytesInFlight = false;
			});
		}

		function updateDeviceGraph() {
			var ip = searchSelect.getValue();
			if (!ip || ip === '__all__') {
				deviceGraphDiv.classList.add('tc-hidden');
				return;
			}
			var hist = self._fullHistory[ip];
			if (!hist || hist.length < 2) return;
			var sm = self._shapeMap[ip], dm = self._dropMap[ip];
			var lk = (sm && sm.rate_kbit > 0) ? sm.rate_kbit : ((dm && dm.rate_kbit > 0) ? dm.rate_kbit : 0);
			var w = deviceGraphDiv.offsetWidth || 560;
			var svg = renderFullGraph(hist, lk, w, 160);
			if (!svg) return;
			while (deviceGraphDiv.firstChild) deviceGraphDiv.removeChild(deviceGraphDiv.firstChild);
			deviceGraphDiv.appendChild(svg);
			deviceGraphDiv.classList.remove('tc-hidden');
		}

		// 立即按当前配置重算并重绘速率相关视图（不等待下一次轮询）。
		//
		// 【本仓库补丁（相对上游 1.21.4）】
		//   「窗口」「方法」等速率参数在上游只是写进 localStorage，要等下一个
		//   轮询周期才由 pollBytes 重新计算，用户观感是「改了没反应」。这里把
		//   「重算 + 重绘」抽出来，供参数变更时即时调用：
		//     - 窗口变小：按新窗口截断历史后重算 avg/max
		//     - 方法切换：按新算法重算（调用方已清空历史与 EWMA）
		//   只重算已有历史，不主动发起网络请求，避免与轮询重复打后端。
		//   上游把上下行存在同一个 _speedHistory（每条 {speed, up, time}），
		//   _speedMap 中上行字段为 current_up / avg_up / max_up。
		function refreshSpeedViews() {
			var o = loadOpts();
			var pollInterval = optPoll(o) || 2;
			var avgWindow = optWindow(o) || 15;
			var avgMethod = o.avgMethod || 'simple';
			var maxSamples = Math.max(2, Math.round(avgWindow / pollInterval));

			var hist = self._speedHistory || {};
			Object.keys(hist).forEach(function(ip) {
				var h = hist[ip];
				if (!h || !h.length) return;
				// 按新窗口截断，让窗口改动「立即生效」而不是下一次才生效
				while (h.length > maxSamples) h.shift();

				var sum = 0, mx = 0, sumUp = 0, mxUp = 0;
				h.forEach(function(p) {
					sum += p.speed; if (p.speed > mx) mx = p.speed;
					var u = p.up || 0;
					sumUp += u; if (u > mxUp) mxUp = u;
				});
				var last = h[h.length - 1] || {};
				var avg, avgUp;
				if (avgMethod === 'ewma') {
					var alpha = 2 / (maxSamples + 1);
					avg = h[0].speed; avgUp = h[0].up || 0;
					for (var i = 1; i < h.length; i++) {
						avg = alpha * h[i].speed + (1 - alpha) * avg;
						avgUp = alpha * (h[i].up || 0) + (1 - alpha) * avgUp;
					}
					self._speedEwma[ip] = avg;
					self._speedEwmaUp[ip] = avgUp;
				} else {
					avg = sum / h.length;
					avgUp = sumUp / h.length;
				}
				self._speedMap[ip] = {
					current: last.speed || 0,
					up: last.up || 0,
					avg: avg,
					max: mx,
					current_up: last.up || 0,
					avg_up: avgUp,
					max_up: mxUp
				};
			});

			if (isAllMode()) updateSpeedCells();
			updateDeviceGraph();
			if (typeof updateExtendedStats === 'function') updateExtendedStats();
		}

		function runSingle(ip) {
			var o = loadOpts();
			var proto = (o.proto && o.proto !== 'all') ? o.proto : '';
			self._queryGen++;
			var gen = self._queryGen;

			// 例行轮询不写「运行中…」（1 秒档位下会一直闪），只在失败时报错。
			// 必须 return：轮询的防重入锁依赖「请求真正结束」才复位
			// （见 _setupTimer 旁的 tick 与 runQuery 的注释）。
			return callDevice(ip, proto).then(function(data) {
				if (!data || data.error) {
					setRoutineStatus(statusDiv, 'error', (data && data.error) || _('Unknown error'));
					return;
				}

				// 【本仓库改动 v0.6.9】原先这里包在 `if (opts.showStats !== false)`
				//   里 —— 「统计」开关已移除，该块恒执行。
				{
					var protoTcp = Number(data.protocols.tcp) || 0;
					var protoUdp = Number(data.protocols.udp) || 0;
					var protoOther = Number(data.protocols.other) || 0;
					var connCount = protoTcp + protoUdp + protoOther;
					var parts = [_('Connections') + ': <b>'+connCount+'</b>'];
					if (connCount > 0) {
						parts.push('TCP: <b>'+protoTcp+'</b>');
						parts.push('UDP: <b>'+protoUdp+'</b>');
						if (data.tcp_states) {
							Object.keys(data.tcp_states).forEach(function(s) {
								parts.push(escHtml(s)+': <b>'+(Number(data.tcp_states[s]) || 0)+'</b>');
							});
						}
					}
					if ((data.shape_kbit || 0) > 0) {
						parts.push(_('Shaped') + ': <b style="color:var(--tc-speed)">🌊 '+fmtRate(data.shape_kbit)+'</b>');
						var sm = self._shapeMap[data.ip || searchSelect.getValue()] || {};
						if ((sm.backlog||0) > 0) parts.push(_('Queued') + ': <b style="color:var(--tc-speed)">'+fmtBytes(sm.backlog)+'</b>');
						if ((sm.bytes||0) > 0) parts.push(_('Passed') + ': <b>'+fmtBytes(sm.bytes)+'</b>');
					} else if ((data.rate_limit_kbit || 0) > 0) {
						parts.push(_('Speed limit') + ': <b style="color:var(--tc-warn)">⚡ '+fmtRate(data.rate_limit_kbit)+'</b>');
						var dm = self._dropMap[data.ip || searchSelect.getValue()] || {};
						if ((dm.packets||0) > 0) {
							parts.push(_('Dropped') + ': <b style="color:var(--tc-err)">🚫 '+(Number(dm.packets) || 0)+' pkts / '+fmtBytes(dm.bytes||0)+'</b>');
						}
					}
					// Listed but still associated is not a block, so it must not
					// read as one — that claim is the whole bug.
					var wifiPart;
					if (data.wifi_blocked && data.wifi_block_pending) {
						wifiPart = ' &nbsp;|&nbsp; <b style="color:var(--tc-err)">📵⚠ ' + _('WiFi block NOT in effect') + '</b> — ' +
							_('on the deny list but still connected; install hostapd-utils or restart WiFi') +
							' ('+escHtml(data.mac||'') + ')';
					} else if (data.wifi_blocked) {
						wifiPart = ' &nbsp;|&nbsp; <b style="color:var(--tc-warn)">📵 ' + _('WiFi blocked') + '</b> ('+escHtml(data.mac||'') + ')';
					} else {
						wifiPart = data.mac ? ' &nbsp;|&nbsp; <span style="color:var(--tc-faint)">MAC: '+escHtml(data.mac)+'</span>' : '';
					}
					// 同 renderSummary：整体赋 className 会丢掉 tc-hidden。
					var sHidden = statsDiv.classList.contains('tc-hidden');
					statsDiv.className = 'alert-message ' + (data.blocked ? 'error' : 'info');
					if (sHidden) statsDiv.classList.add('tc-hidden');
					statsDiv.innerHTML = (data.blocked
						? '<b>⛔ ' + _('BLOCKED') + '</b> — '+(Number(data.block_packets) || 0)+' pkts, '+fmtBytes(Number(data.block_bytes) || 0)+' ' + _('dropped') + ' &nbsp;|&nbsp; '
						: '') + parts.join(' &nbsp;|&nbsp; ') + wifiPart;
					// 单设备模式下统计条刚被填好，卡片可能要显示出来。
					updateOverviewCard();
				}

				updateInetBtn(data.blocked);
				updateWifiBtn(data.wifi_blocked, !!data.mac);

				var curShapeRate = data.shape_kbit || 0;
				var curLimitRate = data.rate_limit_kbit || 0;
				var curRate = curShapeRate > 0 ? curShapeRate : curLimitRate;
				// 【本仓库改动 v0.6.9】速率部件已移进「限制」弹层，故只在
				//   **弹层正开着、且看的就是这台设备**时才回填 —— 否则会把
				//   另一台设备的值写进弹层，或在没打开时白白改动隐藏的部件。
				if (_limitPopupOpen && _limitIp === ip) {
					modePick.setValue(curShapeRate > 0 ? 'shaper' : (curLimitRate > 0 ? 'limiter' : 'shaper'));
					var curRateStr = String(curRate);
					var matched = RATE_PRESETS.some(function(p) { return p.v === curRateStr; });
					// Leave the panel alone entirely while the custom field is
					// open — this runs on every poll.
					if (_customPinned) {
						/* user is editing */
					} else if (matched) {
						ratePick.setValue(curRateStr);
						customRow.classList.add('tc-hidden');
					} else if (curRate > 0) {
						ratePick.setValue('custom');
						customInput.value = curRate;
						_customUnit = 'kbit'; updateUnitBtns();
						customRow.classList.remove('tc-hidden');
					} else {
						ratePick.setValue('0');
						customRow.classList.add('tc-hidden');
					}
				}

				while (connsDiv.firstChild) connsDiv.removeChild(connsDiv.firstChild);
				if (!data.connections || data.connections.length === 0) {
					connsDiv.appendChild(E('p', {'style':'color:var(--tc-muted);padding:12px 0'}, _('No active connections.')));
				} else {
					var groupBy = o.groupBy || 'none';
					var tbl;
					if (groupBy !== 'none') {
						var groups = groupConnections(data.connections, groupBy);
						tbl = buildGroupedTable(groups, self._sortCol === 'bytes' || self._sortCol === 'count' ? self._sortCol : 'bytes', self._sortDir);
						Array.prototype.forEach.call(tbl.querySelectorAll('.th'), function(th) {
							th.addEventListener('click', function() {
								var col = th.getAttribute('data-col');
								if (self._sortCol === col) {
									self._sortDir = self._sortDir === 'asc' ? 'desc' : 'asc';
								} else {
									self._sortCol = col;
									self._sortDir = th.getAttribute('data-num') === '1' ? 'desc' : 'asc';
								}
								runQuery();
							});
						});
						connsDiv.appendChild(E('div',{'style':'overflow-x:auto'},[tbl]));
						connsDiv.appendChild(E('p',{'style':'color:var(--tc-faint);font-size:11px;margin-top:6px'},
							groups.length + ' ' + _('groups from') + ' ' + data.connections.length + ' ' + _('connections') + '. ' + _('Click header to sort.')));
					} else {
						tbl = buildTable(data.connections, self._sortCol, self._sortDir, o.rdns, self._connHiddenCols);
						Array.prototype.forEach.call(tbl.querySelectorAll('.th'), function(th) {
							th.addEventListener('click', function() {
								var col = th.getAttribute('data-col');
								if (self._sortCol === col) {
									self._sortDir = self._sortDir === 'asc' ? 'desc' : 'asc';
								} else {
									self._sortCol = col;
									self._sortDir = th.getAttribute('data-num') === '1' ? 'desc' : 'asc';
								}
								runQuery();
							});
						});
						connsDiv.appendChild(E('div',{'style':'overflow-x:auto'},[tbl]));
						connsDiv.appendChild(E('p',{'style':'color:var(--tc-faint);font-size:11px;margin-top:6px'},
							data.connections.length + ' ' + _('connections') + '. ' + _('Click header to sort.')));

						if (o.rdns) {
							var seen = {}, uncached = [];
							data.connections.forEach(function(c) {
								var dst = c.dst || '';
								if (!dst || seen[dst] || PRIVATE_RE.test(dst)) return;
								seen[dst] = true;
								if (self._rdnsCache[dst] !== undefined) {
									var cached = self._rdnsCache[dst];
									Array.prototype.forEach.call(
										connsDiv.querySelectorAll('[data-dst="'+dst+'"]'),
										function(cell) {
											if (cached) { cell.textContent = cached; cell.style.color = ''; }
											else { cell.innerHTML = '<span class="tc-c-faint">—</span>'; }
										}
									);
								} else {
									uncached.push(dst);
								}
							});
							_rdnsBatch(uncached, gen);
						}
					}
				}
				setRoutineStatus(statusDiv, 'ok', '✓ ' + _('Done'));
			})
			.catch(function(e) { setRoutineStatus(statusDiv, 'error', '✗ '+e.message); });
		}

		self._tableFilter = null;
		self._lastRows = [];
		// 【本仓库改动】分页状态（参照图底部的「每页 N 条」）。
		//   0 表示「全部」。存 localStorage，刷新后保持同一页长。
		self._pageSize = Number(opts.pageSize) || 20;
		self._page = 1;

		function applyTableFilter(rows) {
			var f = self._tableFilter;
			if (!f) return rows;
			if (f === 'blocked') return rows.filter(function(r) { return r.blocked; });
			if (f === 'wifi_blocked') return rows.filter(function(r) { return r.wifi_blocked; });
			if (f === 'limited') return rows.filter(function(r) { return (r.rate_limit_kbit||0) > 0; });
			if (f === 'shaped') return rows.filter(function(r) { return (r.shape_kbit||0) > 0; });
			return rows;
		}

		function setTableFilter(f) {
			self._tableFilter = (self._tableFilter === f) ? null : f;
			renderSummary(self._lastRows);
		}

		// The summary's own total/tcp/udp fields are live conntrack sums, which
		// collapse when flows expire (#26). Replace them with the lifetime
		// totals the byte poll carries, keeping the live values for the cell
		// tooltips. Done on the row objects rather than inside the table
		// builder so that sorting by Bytes sorts by the number on screen.
		function mergeTotals(rows) {
			rows.forEach(function(r) {
				var t = self._totalsMap[r.ip];
				r._total_pending = !t;
				if (!t) {
					r.total = -1; r.tcp = -1; r.udp = -1;
					r._total_degraded = false;
					return;
				}
				r.total = t.total;
				r.tcp = t.tcp;
				r.udp = t.udp;
				r._total_up = t.up;
				r._total_dn = t.dn;
				r._live_total = t.liveTotal;
				r._live_tcp = t.liveTcp;
				r._live_udp = t.liveUdp;
				r._live_up = t.liveUp;
				r._live_dn = t.liveDn;
				r._total_since = t.since;
				r._total_degraded = t.degraded;
			});
		}

		// Repaints the cumulative cells in place on every byte poll, so the
		// totals climb at the poll interval instead of freezing until the next
		// full table rebuild — a counter that only moves every few seconds
		// looks broken in exactly the way this change is meant to fix.
		function updateTotalCells() {
			var specs = [
				['data-total-ip',     'total',    'liveTotal'],
				['data-total-tcp-ip', 'tcp',      'liveTcp'],
				['data-total-udp-ip', 'udp',      'liveUdp'],
				// 累计上行 / 下行同样随字节轮询增长，否则这两列会停在全表重建的那一刻。
				['data-total-up-ip',  'up',       'liveUp'],
				['data-total-dn-ip',  'dn',       'liveDn']
			];
			Object.keys(self._totalsMap).forEach(function(ip) {
				var t = self._totalsMap[ip];
				specs.forEach(function(spec) {
					var cell = connsDiv.querySelector('[' + spec[0] + '="' + ip + '"]');
					if (!cell) {
						return;
					}
					renderTotalCell(cell, t[spec[1]], t[spec[2]], t.since, false, t.degraded);
				});
			});
		}

		function renderSummary(rows) {
			self._lastRows = rows;
			mergeTotals(rows);
			var limited = rows.filter(function(r){return (r.rate_limit_kbit||0) > 0;}).length;
			var shaped  = rows.filter(function(r){return (r.shape_kbit||0) > 0;}).length;
			var blocked = rows.filter(function(r){return r.blocked;}).length;
			var wifiBlk = rows.filter(function(r){return r.wifi_blocked;}).length;
			var wifiPending = rows.filter(function(r){return r.wifi_block_pending;}).length;
			var totalDropPkts = Object.keys(self._dropMap).reduce(function(s, ip) { return s + (self._dropMap[ip].packets||0); }, 0);

			var lnk = 'cursor:pointer;text-decoration:underline;text-decoration-style:dashed';
			var activeFilter = self._tableFilter;

			// className 整体赋值会**丢掉 tc-hidden** —— 关掉「统计」后
			// 下一次 renderSummary 把它写回来，于是统计条照样显示。
			// 故先把隐藏态记下，赋完类名再还原。
			var statsHidden = statsDiv.classList.contains('tc-hidden');
			statsDiv.className = 'alert-message info';
			if (statsHidden) statsDiv.classList.add('tc-hidden');
			while (statsDiv.firstChild) statsDiv.removeChild(statsDiv.firstChild);

			function mkFilterVal(filter, color, text) {
				var active = activeFilter === filter;
				var b = E('b', {'style': lnk+';color:'+color+(active?';font-weight:700':''), 'data-filter': filter}, text);
				return b;
			}

			var parts = [];
			parts.push(E('span', {}, [document.createTextNode(_('Active') + ': '), E('b', {}, String(rows.length))]));
			parts.push(E('span', {}, [document.createTextNode(_('Blocked') + ': '), mkFilterVal('blocked', 'var(--tc-err)', String(blocked))]));
			parts.push(E('span', {}, [document.createTextNode(_('WiFi') + ': '), mkFilterVal('wifi_blocked', 'var(--tc-warn)', String(wifiBlk))]));
			// Without this the header counts a device as blocked on the strength of
			// the uci maclist alone — which is how a router can report "WiFi: 2"
			// while both of those devices are browsing.
			if (wifiPending > 0) {
				parts.push(E('span', {
					'style': 'color:var(--tc-err);font-weight:700;cursor:help',
					'title': _('Devices on the WiFi deny list that are still connected — those blocks are not in effect on the running radio.')
				}, '⚠ ' + wifiPending + ' ' + _('not applied')));
			}
			if (limited > 0) parts.push(E('span', {}, [document.createTextNode(_('Limited') + ': '), mkFilterVal('limited', 'var(--tc-warn)', '⚡' + limited)]));
			if (shaped > 0) parts.push(E('span', {}, [document.createTextNode(_('Shaped') + ': '), mkFilterVal('shaped', 'var(--tc-speed)', '🌊' + shaped)]));
			if (totalDropPkts > 0) {
				parts.push(E('span', {}, [
					document.createTextNode(_('Dropped') + ': '), E('b', {'style':'color:var(--tc-err)'}, '🚫' + totalDropPkts)
				]));
			}

			parts.forEach(function(el, i) {
				if (i > 0) statsDiv.appendChild(E('span', {'style':'margin:0 6px;color:var(--tc-faint)'}, '|'));
				statsDiv.appendChild(el);
				var filterEl = el.querySelector('[data-filter]');
				if (filterEl) {
					filterEl.addEventListener('click', function() { setTableFilter(filterEl.getAttribute('data-filter')); });
				}
			});

			if (activeFilter) {
				statsDiv.appendChild(E('span', {'style':'margin-left:10px;cursor:pointer;color:var(--tc-muted);font-size:11px'}, '✕ ' + _('clear filter')));
				statsDiv.lastChild.addEventListener('click', function() { self._tableFilter = null; renderSummary(rows); });
			}
			// 统计条刚填好内容，卡片可能要由隐藏转为显示。
			updateOverviewCard();

			// Says once, in words, what the ⚠ in every byte cell means. The
			// Flow Offload banner above already explains the mode, but on this
			// hardware its reassurance — that trafficctl switches to nftables
			// counters — is exactly what does not hold.
			if (rows.some(function(r) { return r._total_degraded; })) {
				statsDiv.appendChild(E('div', {
					'style': 'margin-top:8px;padding:6px 8px;border-left:3px solid var(--tc-err);' +
						'background:rgba(211,84,0,0.10);font-size:11px'
				}, [
					E('strong', {}, '⚠ ' + _('Byte totals unavailable on this router.')),
					document.createTextNode(' ' + _('Flow offload is active and the kernel does not support the nftables counter maps trafficctl uses in that mode, so byte counters stop updating for offloaded connections. Speeds and totals would be far too low, so they are not shown. Disabling hardware offload in Settings → Flow Offload restores them.'))
				]));
			}

			var filtered = applyTableFilter(rows);
			while (connsDiv.firstChild) connsDiv.removeChild(connsDiv.firstChild);
			if (filtered.length === 0) {
				connsDiv.appendChild(E('p',{'style':'color:var(--tc-muted);padding:12px 0'}, _('No devices match filter.')));
			} else {
				// 【本仓库改动】分页：只把当前页交给表格构建器。
				//   必须在**排序之后**切片才有意义，故先让 buildSummaryTable 排序
				//   就不可行 —— 它是构建并排序一体的。这里改为：先按当前排序列
				//   对 filtered 排一次序（与 buildSummaryTable 内同一套规则），
				//   再切片，然后把切片交给它（它会对切片再排一次，结果一致）。
				var sortedAll = sortSummaryRows(filtered, self._sumCol, self._sumDir);
				var pageSize = self._pageSize > 0 ? self._pageSize : sortedAll.length;
				var pageCount = Math.max(1, Math.ceil(sortedAll.length / pageSize));
				if (self._page > pageCount) self._page = pageCount;
				if (self._page < 1) self._page = 1;
				var start = (self._page - 1) * pageSize;
				var pageRows = sortedAll.slice(start, start + pageSize);

				var tbl = buildSummaryTable(
					pageRows,
					self._sumCol,
					self._sumDir,
					function(key, isNum) {
						if (self._sumCol === key) {
							self._sumDir = self._sumDir === 'asc' ? 'desc' : 'asc';
						} else {
							self._sumCol = key;
							self._sumDir = isNum ? 'desc' : 'asc';
						}
						self._page = 1;
						renderSummary(rows);
					},
					function(ip) {
						var dev = rows.filter(function(r) { return r.ip === ip; })[0];
						var lbl = dev && dev.name && dev.name !== '*' ? dev.name + '  —  ' + ip : ip;
						searchSelect.setValue(ip, lbl);
						var o = loadOpts(); o.lastIp = ip; saveOpts(o); updateUrlParams(o);
						updateModeUI();
						runQuery();
					},
					self._speedMap,
					self._dropMap,
					self._shapeMap,
					self._speedHistory,
					self._hiddenCols,
					// 【本仓库改动 v0.6.9】「限制」链接直接打开该设备的限速弹层。
					function(cell, ip, name) { openLimitPopup(cell, ip, name); }
				);
				connsDiv.appendChild(E('div',{'style':'overflow-x:auto'},[tbl]));
				connsDiv.appendChild(mkPager(sortedAll.length, start, pageRows.length, pageCount));
				connsDiv.appendChild(E('p',{'style':'color:var(--tc-faint);font-size:11px;margin-top:6px'},
					_('Click a row to inspect that device. Download and upload speeds update every 2 seconds.')));
			}
		}

		// 与 buildSummaryTable 内的排序规则保持一致（否则分页切片的顺序与
		// 表内最终顺序不同，会出现「第一页不是最快的设备」这种怪现象）。
		function sortSummaryRows(rows, sortCol, sortDir) {
			function ipToInt(s) {
				var p = String(s||'').split('.');
				if (p.length !== 4) return 0;
				return ((parseInt(p[0])||0)*16777216 + (parseInt(p[1])||0)*65536 + (parseInt(p[2])||0)*256 + (parseInt(p[3])||0));
			}
			return rows.slice().sort(function(a, b) {
				var av = a[sortCol], bv = b[sortCol];
				if (typeof av === 'number') {
					var diff = sortDir === 'asc' ? av - bv : bv - av;
					if (diff !== 0) return diff;
					return String(a.name || '').localeCompare(String(b.name || ''));
				}
				if (typeof av === 'boolean') return sortDir === 'asc' ? (av?1:0)-(bv?1:0) : (bv?1:0)-(av?1:0);
				if (sortCol === 'ip') {
					var d = ipToInt(av) - ipToInt(bv);
					return sortDir === 'asc' ? d : -d;
				}
				av = String(av||''); bv = String(bv||'');
				return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
			});
		}

		// 底部分页条：左侧「共 N 条 当前显示 a-b」，右侧「每页 N 条」+ 页码。
		// 只在「所有设备」模式下出现（单设备模式只有一行数据，分页没有意义）。
		function mkPager(total, start, shown, pageCount) {
			var sizes = [20, 50, 100, 0];
			var sizeLabels = { 20:'20', 50:'50', 100:'100' };
			var sel = E('select', {'class':'cbi-input-select', 'style':'margin:0 4px'}, sizes.map(function(s) {
				return E('option', { 'value': String(s), 'selected': (self._pageSize === s) ? 'selected' : undefined },
					s === 0 ? _('All') : sizeLabels[s]);
			}));
			sel.addEventListener('change', function() {
				self._pageSize = parseInt(sel.value, 10) || 0;
				self._page = 1;
				var o = loadOpts(); o.pageSize = self._pageSize; saveOpts(o);
				renderSummary(self._lastRows);
			});

			function pageBtn(label, page, disabled, active) {
				var b = E('span', {
					'class': 'tc-page-btn' + (active ? ' tc-page-btn--active' : '') + (disabled ? ' tc-page-btn--disabled' : ''),
					'style': disabled ? 'pointer-events:none;opacity:.45' : ''
				}, label);
				if (!disabled && !active) b.addEventListener('click', function() { self._page = page; renderSummary(self._lastRows); });
				return b;
			}

			var nav = [];
			nav.push(pageBtn('«', 1, self._page <= 1, false));
			nav.push(pageBtn('‹', self._page - 1, self._page <= 1, false));
			// 页码窗口：当前页 ±2，最多 5 个。
			var from = Math.max(1, self._page - 2), to = Math.min(pageCount, from + 4);
			from = Math.max(1, to - 4);
			for (var p = from; p <= to; p++) nav.push(pageBtn(String(p), p, false, p === self._page));
			nav.push(pageBtn('›', self._page + 1, self._page >= pageCount, false));
			nav.push(pageBtn('»', pageCount, self._page >= pageCount, false));

			return E('div', {'class':'tc-pager'}, [
				E('span', {'class':'tc-pager__info'}, _('Total') + ' ' + total + ' ' + _('items') +
					'  ' + _('showing') + ' ' + (total === 0 ? 0 : start + 1) + '-' + (start + shown)),
				E('span', {'class':'tc-pager__right'}, [
					E('span', {}, _('Per page')), sel, E('span', {}, _('items')),
					E('span', {'style':'margin:0 10px;color:var(--tc-faint)'}, '|'),
					E('span', {}, nav)
				])
			]);
		}

		function runAll() {
			// 例行轮询不写「扫描中…」（1 秒档位下会一直闪），只在失败时报错。
			// 必须 return：轮询的防重入锁依赖「请求真正结束」才复位
			// （见 _setupTimer 旁的 tick 与 runQuery 的注释）。
			return callTrafficctl().then(function(rows) {
				if (!Array.isArray(rows)) rows = [];
				searchSelect.updateDevices(rows);
				renderSummary(rows);

				// Breakdown for the App column tooltips; fire-and-forget so a
				// missing or slow netifyd never delays the table.
				if (rows.some(function(r) { return r.app; })) {
					callNetifyList().then(function(list) {
						if (!Array.isArray(list)) return;
						var m = {};
						list.forEach(function(d) { m[d.ip] = d; });
						netifyMap = m;
					}).catch(function() {});
				}
				setRoutineStatus(statusDiv, 'ok', '✓ ' + _('Done'));
				self._startBytesPoll();
			})
			.catch(function(e) { setRoutineStatus(statusDiv, 'error', '✗ '+e.message); });
		}

		function updateExtendedStats() {
			var o = loadOpts();
			if (!o.extendedStats) return;
			while (extStatsDiv.firstChild) extStatsDiv.removeChild(extStatsDiv.firstChild);
			var ip = searchSelect.getValue();
			if (ip === '__all__') {
				extStatsDiv.appendChild(buildExtendedStatsLegend(self._shapeMap, self._dropMap));
			} else {
				extStatsDiv.appendChild(buildExtendedStatsPanel(ip, self._shapeMap, self._dropMap, self._speedMap));
			}
		}

		function runQuery() {
			var ip = searchSelect.getValue();
			var o = loadOpts(); o.lastIp = ip; saveOpts(o);
			updateUrlParams(o);
			updateModeUI();
			// Switching between all-devices and a single device changes which
			// timers should be running, so tear them down and let the branch
			// below start the right set.
			var mode = (ip === '__all__') ? 'all' : 'device';
			if (self._pollMode !== mode) {
				self._pollMode = mode;
				self._stopBytesPoll();
			}
			// 返回值必须是 promise：轮询的防重入锁（见 _setupTimer 旁的 tick）
			// 依赖它在请求**真正结束**后才复位。runAll/runSingle 本身返回
			// promise，这里把 updateExtendedStats 也纳入同一条链，保证锁覆盖
			// 整个刷新过程（而不只是发起请求那一刻）。
			var p;
			if (ip === '__all__') {
				deviceGraphDiv.classList.add('tc-hidden');
				p = runAll();
			} else {
				p = runSingle(ip);
				self._startBytesPoll();
			}
			if (p && typeof p.then === 'function') {
				return p.then(function(r) { updateExtendedStats(); return r; },
				              function(e) { updateExtendedStats(); throw e; });
			}
			updateExtendedStats();
			return Promise.resolve();
		}

		// rateBtn handler removed — applyRate() is called directly from chip clicks

		wifiBtn.addEventListener('click', function() {
			var ip   = searchSelect.getValue();
			var action = wifiBtn._wifiAction;
			wifiBtn.disabled = true;
			var name = '';
			setStatus(statusDiv, 'loading', (action==='block' ? _('Adding to') : _('Removing from')) + ' ' + _('WiFi deny list') + ': ' + name + '…');
			var fn = action === 'block' ? callMacfilterAdd : callMacfilterRemove;
			fn(ip).then(function(res) {
				// res.ok is now true only when the RUNNING radio was verified to
				// carry the change, so a config-only write must not paint green.
				// "ban" is the partial middle state (temporary hostapd ban, no
				// ACL) and gets the attention colour rather than a hard error.
				var state;
				if (res && res.ok) {
					state = (action === 'block') ? 'action' : 'ok';
				} else if (res && res.enforcement === 'ban') {
					state = 'action';
				} else {
					state = 'error';
				}
				setStatus(statusDiv, state, (res && res.msg) || '?');
				runQuery();
			}).catch(function(e) {
				setStatus(statusDiv, 'error', '✗ '+e.message);
			}).then(function() {
				wifiBtn.disabled = false;
			});
		});

		inetBtn.addEventListener('click', function() {
			var ip = searchSelect.getValue();
			if (!ip || ip === '__all__') return;
			inetBtn.disabled = true;
			var action = inetBtn._action;
			var fn = action === 'block' ? callBlock : callUnblock;
			fn(ip, '').then(function(res) {
				// A block without a known MAC covers IPv4 only, and the backend
				// says so in msg. Swallowing it here would put the UI back to
				// reporting a block that does not block (issue #67).
				if (res && res.ipv6 === false) {
					setStatus(statusDiv, 'error', (res && res.msg) || '?');
				}
				runQuery();
			}).catch(function(e) {
				setStatus(statusDiv, 'error', e.message);
			}).then(function() {
				inetBtn.disabled = false;
			});
		});

		this._setupTimer = function() {
			if (self._timer) { clearInterval(self._timer); self._timer = null; }
			// 【本仓库补丁】用 optRefresh 而非直接读 loadOpts().refresh：
			// 未设置时取默认 5 秒，保证**冷启动即自动刷新**（上游为 0=关）。
			var iv = parseInt(optRefresh(loadOpts()), 10) || 0;
			if (iv > 0) self._timer = setInterval(tick, iv*1000);
		};

		// 【本仓库补丁】轮询必须防重入。
		//
		// 为什么：`summary` 这个 ubus 调用在 23 台设备的路由上实测要 **1.9 秒**
		// （它要读完整 conntrack 表 + nft 链 + tc 类）。而本仓库把刷新档位放到了
		// 1s/2s（用户要求「最低按 1 秒刷新」）。若照上游那样直接
		// `setInterval(runQuery, 1000)`，浏览器会每 1 秒发起一次、每次要 1.9 秒
		// 才回，请求就会**层层堆积**：rpcd 侧不断 fork `trafficctl-summary.sh`，
		// 路由器 load 飙高、页面反而卡住甚至 XHR 超时。
		//
		// 正确做法是「上一次没回来就跳过这一拍」。这样即使档位设成 1s，实际速率
		// 也自动退化为后端能承受的 ~1.9s，不会堆积。
		var queryInFlight = false;
		function tick() {
			if (queryInFlight) return;          // 上一拍还在跑，跳过
			if (document.hidden) return;        // 页面不可见时不轮询，省路由器开销
			queryInFlight = true;
			self._queryInFlight = true;
			try {
				// runQuery 内部是 then/catch 链，返回的是 Promise（runAll/runSingle
				// 都返回 promise）。用它来复位标志，确保任何路径都会解锁。
				var p = runQuery();
				if (p && typeof p.then === 'function') {
					p.then(unlock, unlock);
				} else {
					unlock();
				}
			} catch (e) {
				unlock();
				throw e;
			}
		}
		function unlock() {
			queryInFlight = false;
			self._queryInFlight = false;
		}

		this._startBytesPoll = function() {
			if (self._bytesTimer) return;
			var o = loadOpts();
			var pollMs = optPoll(o) * 1000;
			if (pollMs <= 0) return;
			pollBytes();
			self._bytesTimer = setInterval(pollBytes, pollMs);
			pollDrops();
			self._dropTimer = setInterval(pollDrops, 5000);
			pollShapeStats();
			self._shapeTimer = setInterval(pollShapeStats, 5000);
			// Device view: keep the connection table live as well, instead of
			// freezing until the user manually refreshes. Floored at 3s because
			// this re-reads conntrack for the device on every tick.
			if (!isAllMode()) {
				self._deviceTimer = setInterval(function() {
					if (document.hidden) return;
					var ip = searchSelect.getValue();
					if (ip && ip !== '__all__') runSingle(ip);
				}, Math.max(pollMs, 3000));
			}
		};
		this._stopBytesPoll = function() {
			if (self._bytesTimer)  { clearInterval(self._bytesTimer);  self._bytesTimer  = null; }
			if (self._dropTimer)   { clearInterval(self._dropTimer);   self._dropTimer   = null; }
			if (self._shapeTimer)  { clearInterval(self._shapeTimer);  self._shapeTimer  = null; }
			if (self._deviceTimer) { clearInterval(self._deviceTimer); self._deviceTimer = null; }
		};
		this._restartBytesPoll = function() {
			self._stopBytesPoll();
			self._startBytesPoll();
		};

		this._setupTimer();
		setTimeout(function() { runQuery(); }, 0);

		var savedHidden = opts.hiddenCols || {};
		self._hiddenCols = savedHidden;

		// 【本仓库改动 v0.6.8】可见列清单只含**默认隐藏**的列。
		//   默认就显示的列（IP/MAC、连接数、四个速率列、类型厂商、名称、操作、
		//   TCP、UDP、互联网、限制）不列进来 —— 它们本来就看得见，再给一个
		//   开关只会让人以为「没勾上就是没有」。
		//   与 buildSummaryTable 的 cols 保持同源：key 必须都在 cols 里，
		//   且恰好是 cols 中默认隐藏的那一批（断言按此校验）。
		var colChipDefs = [
			{key:'mac',           label:'MAC'},
			{key:'_spark',        label:_('Graph')},
			{key:'total',         label:_('Bytes')},
			{key:'conn_type',     label:_('Link')},
			{key:'app',           label:_('App')},
			{key:'_drop_packets', label:_('Drops')},
			{key:'_backlog',      label:_('Queue')}
		];
		// 复选框**一行一个**（原先是挤在一起的圆形 chip，多到五行、每行长短
		// 不一，要在一堆同色小圆里找某一列）。一行一个复选框：命中区域大、
		// 对齐整齐、状态一眼可读。
		var colChipsContainer = E('div', {'class':'tc-col-checks'});
		colChipDefs.forEach(function(ct) {
			var cb = E('input', {
				'type': 'checkbox',
				'class': 'tc-col-check__box',
				'id': 'tc-col-' + ct.key
			});
			cb.checked = !isColHidden(ct.key, savedHidden);
			var row = E('label', {
				'class': 'tc-col-check',
				'for': 'tc-col-' + ct.key,
				'data-tip': _('Show this column in the device table')
			}, [cb, E('span', {'class':'tc-col-check__label'}, ct.label)]);
			cb.addEventListener('change', function() {
				// 【关键】两个方向都写**显式布尔**，不用 delete。
				//   delete 之后 isColHidden 会回落到默认隐藏，于是「勾上」
				//   看起来毫无作用（勾是勾了、表格里却没有这一列）。
				//   写显式值还让用户的选择能抵御后续默认值变化。
				self._hiddenCols[ct.key] = !cb.checked;
				var o = loadOpts(); o.hiddenCols = self._hiddenCols; saveOpts(o);
				if (isAllMode()) runAll();
			});
			colChipsContainer.appendChild(row);
		});

		// Per-device connection table column toggles
		var connColDefs = [
			{key:'proto', label:_('Proto')}, {key:'dst', label:_('Dst IP')},
			{key:'host', label:_('Hostname')}, {key:'port', label:_('Port')},
			{key:'service', label:_('Service')}, {key:'bytes', label:_('Bytes')},
			{key:'state', label:_('State')}, {key:'oif', label:_('Iface')}
		];
		// 'oif' (egress interface) is only populated for policy-routed (mwan3)
		// connections, so hide it by default; users on such setups enable it
		// via the column chip.
		var savedConnHidden = opts.connHiddenCols || { oif: true };
		self._connHiddenCols = savedConnHidden;
		var connColChipsContainer = E('div', {'class':'tc-chips-wrap'});
		connColDefs.forEach(function(ct) {
			var chip = E('span', {
				'class': savedConnHidden[ct.key] ? 'tc-col-chip tc-col-chip--off' : 'tc-col-chip tc-col-chip--on',
				'data-tip': _('Click to toggle column visibility')
			}, ct.label);
			chip.addEventListener('click', function() {
				if (self._connHiddenCols[ct.key]) { delete self._connHiddenCols[ct.key]; chip.className = 'tc-col-chip tc-col-chip--on'; }
				else { self._connHiddenCols[ct.key] = true; chip.className = 'tc-col-chip tc-col-chip--off'; }
				var o = loadOpts(); o.connHiddenCols = self._connHiddenCols; saveOpts(o);
				if (!isAllMode()) runQuery();
			});
			connColChipsContainer.appendChild(chip);
		});

		// 连接表筛选（协议 / 分组）。此前它随其它设置项一起定义在下方，
		// v0.6.0 把配置区迁走时该定义被一并删除，而 viewSection 与
		// updateTableSectionMode 仍在引用它 → 「connFiltersRow is not defined」
		// 令整页 render 抛错、页面空白。故定义必须留在引用之前。
		var connFiltersRow = E('div', {'class':'tc-conn-filters-row'}, [
			E('span', {'data-tip':_('Filter connections by protocol')}, [T.mkLabel(_('Proto')+':'), protoPick.el]),
			T.sep(),
			E('span', {'data-tip':_('Group connections table rows')}, [T.mkLabel(_('Group')+':'), groupPick.el])
		]);

		// 【本仓库改动】sep / sectionLabel / mkCollapsible 原先在此定义，
		// 因设置区迁出后本页只剩连接表一处使用，且它们已在
		// trafficctl/common.js 中有同一份实现，故删除本地副本，直接用 T.*。

		// ── 本页视图与表格 ────────────────────────────────────────────────
		//
		// 【本仓库改动】原先这些开关裹在一张可折叠卡片「视图与表格」里，
		//   与「可见列」chip 挤在一起。现按用途拆成两处：
		//     ① **开关**（v0.6.9 起只剩「扩展统计」与「反向DNS」）直接展示在
		//        速率限制卡片尾部 —— 它们各自决定一段内容显不显示。
		//     ② **可见列**（设备列 chip、连接表列 chip、连接表筛选）收进一个
		//        「可见列」按钮的浮层，与 ☰ 组成按钮组（可见列 | ☰）。
		//        这些是「调表的显示」，平时不动，却数量最多、最占横向空间。
		var togglesRow = E('div', {'class':'tc-view-toggles'}, [
			extStatsCheck, rdnsCheck
		]);

		// 「可见列」浮层面板：设备列 / 连接表列 / 连接表筛选。
		var visibleColsMenu = mkPopupMenu({
			text: _('Visible columns'),
			tip: _('Choose which columns the device table and the connection table show')
		});
		visibleColsMenu.panel.appendChild(E('div', {'class':'tc-menu__label'}, _('Visible columns')));
		visibleColsMenu.panel.appendChild(colChipsContainer);
		visibleColsMenu.panel.appendChild(connColChipsContainer);
		visibleColsMenu.panel.appendChild(connFiltersRow);

		// 【本仓库改动】原先是单独一行右对齐的 ☰。现两个菜单并列成一组：
		// 「可见列 | ☰」。
		var tableSpeedBar = E('div', {'class':'tc-menu-group'}, [
			visibleColsMenu.bar,
			speedMenu.bar
		]);

		// 整表列 chip 与连接表筛选只在各自模式下有意义：全局模式看设备列，
		// 单设备模式看连接表列与筛选。不隐藏的话两组会同时出现并互相误导。
		function updateTableSectionMode() {
			var all = isAllMode();
			colChipsContainer.classList.toggle('tc-hidden', !all);
			connColChipsContainer.classList.toggle('tc-hidden', all);
			connFiltersRow.classList.toggle('tc-hidden', all);
		}
		updateTableSectionMode();

		// 【本仓库改动】开关行直接挂在速率限制卡片尾部（原先是可折叠卡片，
		//   挂在 panelTail）。它不再需要外框 —— 目标是「一眼看到所有开关」。
		panelTail.appendChild(togglesRow);

		function loadActivityPanel(container) {
			container.className = 'tc-activity-panel';
			var statusSpan = E('span', {'style':'font-size:12px;color:var(--tc-muted)'}, _('Loading…'));
			container.appendChild(statusSpan);

			callActivityLog(100).then(function(res) {
				while (container.firstChild) container.removeChild(container.firstChild);
				if (!res || !res.lines || !res.lines.length) {
					container.appendChild(E('div', {'style':'font-size:12px;color:var(--tc-muted)'}, _('No activity recorded yet.')));
					return;
				}
				var logArea = E('div', {'class':'tc-log-area'});
				var lines = res.lines.slice().reverse();
				lines.forEach(function(line) {
					var lineEl = E('div', {'class':'tc-log-line'});
					lineEl.textContent = line;
					logArea.appendChild(lineEl);
				});
				var refreshBtn = E('button', {
					'class': 'cbi-button',
					'style': 'font-size:11px;padding:2px 10px;margin-top:6px'
				}, _('Refresh'));
				refreshBtn.addEventListener('click', function() {
					while (container.firstChild) container.removeChild(container.firstChild);
					container._loaded = false;
					loadActivityPanel(container);
				});
				container.appendChild(logArea);
				container.appendChild(refreshBtn);
			}).catch(function(e) {
				statusSpan.textContent = '✗ ' + e.message;
				statusSpan.style.color = 'var(--tc-err)';
			});
		}

		// 活动日志恒显（v0.6.9）：内容必须在首屏就加载 —— 原先这一步挂在
		// 「活动日志」开关的勾选回调里，开关移除后就没人触发了。
		activityDiv._loaded = true;
		loadActivityPanel(activityDiv);

		callVersion().then(function(res) {
			var el = document.getElementById('tc-version-footer');
			if (el && res && res.version) {
				el.textContent = 'trafficctl v' + res.version + ' (' + TRAFFICCTL_BUILD + ')';
			}
		});

		var mkOffloadBanner = function(mode) {
			if (!mode || mode === 'none') return null;

			// 【本仓库改动】软件卸载**不再**出横幅。软件卸载不损失任何功能
			// （速率由图上的 nftables 计数器提供，限速与阻断照常），却每次打开
			// 页面都弹一条橙黄色公告，用户明确要求移除；模式本身在设置页的
			// 「流量卸载」卡片里有常驻显示，不靠横幅告知。
			if (mode === 'software' || mode === 'software-counter') return null;

			var bg, border, icon, body;
			var para = function(text) { return E('p', {'style': 'margin:6px 0'}, text); };
			var bold = function(text) { return E('strong', {}, text); };
			var link = function(url, text) {
				return E('a', {'href': url, 'target': '_blank',
					'style': 'color:inherit;text-decoration:underline'}, text);
			};

			var openwrtUrl = 'https://openwrt.org/docs/guide-user/perf_and_log/flow_offloading';
			var kernelUrl  = 'https://docs.kernel.org/networking/nf_flowtable.html#hardware-offload';
			var nftUrl     = 'https://wiki.nftables.org/wiki-nftables/index.php/Flowtables';

			var sep = E('span', {'style': 'opacity:0.35;margin:0 6px'}, '|');
			var docLinks = para([
				link(openwrtUrl, 'OpenWrt: Flow offloading ↗'), sep.cloneNode(true),
				link(kernelUrl,  'Linux kernel: nf_flowtable ↗'), sep.cloneNode(true),
				link(nftUrl,     'nftables: Flowtables ↗')
			]);

			if (mode === 'hardware-counter') {
				bg     = 'rgba(211,84,0,0.10)';
				border = '#d35400';
				icon   = '⚠️';
				body   = E('div', {}, [
					para(bold(_('Hardware flow offloading active — real-time speed monitoring unavailable.'))),
					para([_('The flowtable '),
						E('code', {}, 'counter'),
						_(' flag should sync hardware byte counts back to conntrack, but on many ' +
						  'platforms (e.g. Mediatek Filogic) the driver does not implement the stats ' +
						  'callback, so conntrack counters remain frozen for active flows.')]),
					para(bold(_('To restore speed monitoring:'))),
					E('ul', {'class': 'tc-offload-ul'}, [
						E('li', {}, [
							_('Disable hardware offload (keeps software offload): '),
							E('code', {}, 'uci set firewall.@defaults[0].flow_offloading_hw=0 && uci commit firewall && fw4 reload'),
						]),
						E('li', {}, _('Or disable all flow offload in LuCI → Network → Firewall → General Settings.')),
					]),
					para(_('Blocking, rate limiting, and traffic shaping continue to work regardless.')),
					docLinks,
				]);
				} else if (mode === 'hardware') {
				bg     = 'rgba(211,84,0,0.10)';
				border = '#d35400';
				icon   = '⚠️';
				body   = E('div', {}, [
					para(bold(_('Hardware flow offloading is active.'))),
					para(_('The router offloads established connections from the CPU to the hardware (NIC/SoC), ' +
						  'achieving 2–3× higher throughput and lower CPU usage.')),
					para(_('In this mode the kernel\'s conntrack, firewall, and tc are bypassed for offloaded flows:')),
					E('ul', {'class': 'tc-offload-ul'}, [
						E('li', {}, _('Speed monitoring — conntrack byte counters are not updated')),
						E('li', {}, _('Traffic shaping (tc/HTB) — bypassed for offloaded flows')),
						E('li', {}, _('Rate limiting — applies only to new connections')),
					]),
					para([_('WiFi blocking and internet blocking of new connections still work. '),
						_('Shaped devices are usually not offloaded (kernel detects the HTB qdisc).')]),
					para(bold(_('How to get full functionality without disabling offload:'))),
					para([_('The flowtable '),
						E('code', {}, 'counter'),
						_(' flag (Linux 5.7+, set automatically by fw4/nftables) periodically syncs ' +
						  'hardware byte counts back to conntrack — trafficctl detects this and all features work normally.')]),
					para(_('If your current firmware uses fw3 (iptables) or ships a kernel older than 5.7, ' +
						  'a router with modern OpenWrt and fw4 support will have this working out of the box.')),
					docLinks,
				]);
			} else {
				// 兜底：software 已在函数开头直接返回 null，hardware 与
				// hardware-counter 在上面各自处理，故这个分支只会在将来新增
				// 未知 mode 值时走到。此前它是一个软件卸载说明分支，现已随
				// 橙色横幅一并删除，留一条保守告警以免未知模式下边框/背景为
				// undefined 而渲染出无边框的裸文本。
				bg     = 'rgba(211,84,0,0.10)';
				border = '#d35400';
				icon   = '⚠️';
				body   = E('div', {}, [
					para(bold(_('Flow offloading is active.'))),
					para(_('Speed monitoring and traffic shaping may be bypassed for offloaded flows.')),
					docLinks,
				]);
			}

			var banner = E('div', {
				'class': 'tc-offload-banner',
				'style': 'border:1px solid ' + border + ';background:' + bg
			}, [
				E('div', {'class': 'tc-offload-banner__row'}, [
					E('span', {'class': 'tc-offload-banner__icon'}, icon),
					E('div', {'class': 'tc-offload-banner__body'}, body),
					E('span', {
						'class': 'tc-offload-banner__close',
						'title': _('Dismiss')
					}, '×')
				])
			]);
			banner.firstChild.lastChild.addEventListener('click', function() {
				banner.classList.add('tc-hidden');
			});
			return banner;
		};

		var offloadBanner = E('div', {'id': 'tc-offload-banner', 'class': 'tc-hidden'});

		// Debug: add ?offload_debug=1 to URL to preview all banner types at once
		if (window.location.search.indexOf('offload_debug') !== -1) {
			['hardware-counter', 'hardware'].forEach(function(mode) {
				var b = mkOffloadBanner(mode);
				if (b) offloadBanner.appendChild(b);
			});
			offloadBanner.classList.remove('tc-hidden');
		} else {
			callConfigGet().then(function(cfg) {
				var b = mkOffloadBanner(cfg && cfg.offload_mode);
				if (!b) return;
				offloadBanner.appendChild(b);
				offloadBanner.classList.remove('tc-hidden');
			});
		}

		// ── Global internet cut (#55) ──────────────────────────────────────
		//
		// 【本仓库改动】容器已在上方随 rateLimitRow 一起创建（并挂进那张卡片），
		//   此处只保留行为：CUT_DURATIONS、提交与渲染。
		//   仍然常显：这是本应用唯一能把操作者自己关在门外的控件，其状态必须
		//   在页面渲染出来的一刻就可读，不藏进任何折叠区。
		var CUT_DURATIONS = [
			{ v: '900',   l: _('15 min') },
			{ v: '3600',  l: _('1 hour') },
			{ v: '14400', l: _('4 hours') },
			{ v: '0',     l: _('Until I switch it back') }
		];

		var cutDuration = null;
		var cutPersist = null;
		var cutArmed = false;
		var cutArmTimer = null;

		function fmtCutRemaining(secs) {
			var h, m;
			if (secs <= 0) { return _('under a minute'); }
			h = Math.floor(secs / 3600);
			m = Math.floor((secs % 3600) / 60);
			if (h > 0) { return h + ' ' + _('h') + ' ' + m + ' ' + _('min'); }
			if (m > 0) { return m + ' ' + _('min'); }
			return secs + ' ' + _('s');
		}

		function cutDisarm() {
			cutArmed = false;
			if (cutArmTimer) { clearTimeout(cutArmTimer); cutArmTimer = null; }
		}

		function cutSubmit(active, status) {
			cutDisarm();
			status.textContent = active ? _('Cutting…') : _('Restoring…');
			status.style.color = 'var(--tc-muted)';
			callCutSet(active, parseInt(cutDuration, 10) || 0, !!cutPersist).then(function(res) {
				if (res && res.ok) {
					renderCut(res);
				} else {
					status.textContent = '✗ ' + ((res && res.msg) || _('failed'));
					status.style.color = 'var(--tc-err)';
				}
			}).catch(function(e) {
				status.textContent = '✗ ' + (e.message || e);
				status.style.color = 'var(--tc-err)';
			});
		}

		// 基类必须是常量：renderCut 每次重绘都要重设 className（切换
		// --on/--broken 状态），若各处手写 'tc-cut' 就会把 --embedded 抹掉，
		// 面板又变回带外框的独立卡片。
		var CUT_BASE = 'tc-cut tc-cut--embedded';

		function renderCut(st) {
			var status, btn, hint, persistToggle, pick, note, devs;

			while (cutPanel.firstChild) { cutPanel.removeChild(cutPanel.firstChild); }
			if (!st) { return; }

			if (cutDuration === null) { cutDuration = String(st.default_duration); }
			if (cutPersist === null) { cutPersist = !!st.default_persist; }

			// nft is the only backend this is implemented on; saying so beats
			// offering a button that would quietly do nothing.
			if (st.supported === false) {
				cutPanel.className = CUT_BASE;
				cutPanel.appendChild(E('div', {'class': 'tc-cut__row'}, [
					E('span', {'class': 'tc-cut__icon'}, '⊘'),
					E('span', {'class': 'tc-c-muted'},
						_('Global internet cut needs nftables (fw4). This router is running iptables.'))
				]));
				return;
			}

			status = E('span', {'class': 'tc-save-status'});
			devs = st.lan_devices || '';

			// The dangerous state: the toggle says on, the rule is gone. Never
			// render this as ON — a lapsed cut with an ON-looking UI is exactly
			// the failure this feature is supposed to not have.
			if (st.active && !st.rule_present) {
				cutPanel.className = CUT_BASE + ' tc-cut--broken';
				btn = E('button', {'class': 'btn cbi-button-negative'}, _('Switch it off'));
				btn.addEventListener('click', function() { cutSubmit(false, status); });
				cutPanel.appendChild(E('div', {'class': 'tc-cut__row'}, [
					E('span', {'class': 'tc-cut__icon'}, '⚠'),
					E('div', {'class': 'tc-cut__body'}, [
						E('b', {}, _('The internet cut is switched on, but its firewall rule is missing.')),
						E('div', {'class': 'tc-cut__hint'},
							_('Traffic is flowing right now. It is normally re-asserted within seconds — if this persists, switch it off and on again.'))
					]),
					btn, status
				]));
				return;
			}

			if (st.active) {
				cutPanel.className = CUT_BASE + ' tc-cut--on';
				btn = E('button', {'class': 'btn cbi-button-positive'}, _('Restore internet'));
				btn.addEventListener('click', function() { cutSubmit(false, status); });

				note = st.expires_at && st.expires_at !== 0
					? _('Restores by itself in') + ' ' + fmtCutRemaining(st.remaining)
					: _('Stays off until you switch it back.');

				hint = E('div', {'class': 'tc-cut__hint'}, [
					E('span', {}, note),
					E('span', {}, ' · '),
					E('span', {}, _('LAN keeps working') + (devs ? ' (' + devs + ')' : ''))
				]);
				// A forward-only cut misses anything a transparent proxy
				// intercepts at prerouting and delivers locally, so the
				// reduced guarantee is stated rather than left implied.
				if (st.coverage === 'forward') {
					hint.appendChild(E('div', {'class': 'tc-cut__warn'},
						_('Forwarded traffic only — this kernel cannot install the prerouting rule, ' +
						  'so traffic handled by a transparent proxy on the router would not be caught.')));
				}
				if (st.persist) {
					hint.appendChild(E('div', {'class': 'tc-cut__warn'},
						_('Kept after reboot — undoing it needs LAN or physical access.')));
				}
				if (!st.keeper_running) {
					hint.appendChild(E('div', {'class': 'tc-cut__warn'},
						_('The auto-revert helper is not running; this page re-checks the deadline while it is open.')));
				}

				cutPanel.appendChild(E('div', {'class': 'tc-cut__row'}, [
					E('span', {'class': 'tc-cut__icon'}, '⛔'),
					E('div', {'class': 'tc-cut__body'}, [
						E('b', {}, _('Internet is cut for all devices')),
						hint
					]),
					btn, status
				]));
				return;
			}

			// ── Off: offer the cut ──
			cutPanel.className = CUT_BASE;
			pick = mkChipPick(CUT_DURATIONS, cutDuration, function(v) {
				cutDuration = v;
				cutDisarm();
				btn.textContent = _('Cut internet');
				btn.className = 'btn cbi-button-negative';
			});

			// Its own opt-in, never the global persist_rules flag: somebody who
			// turned that on so their rate limits survive a reboot must not
			// inherit a persistent internet kill from it.
			persistToggle = mkToggle('tm-cut-persist', _('Keep after reboot'), cutPersist, function() {
				cutPersist = this.checked;
				cutDisarm();
				btn.textContent = _('Cut internet');
				btn.className = 'btn cbi-button-negative';
				persistNote.classList.toggle('tc-hidden', !cutPersist);
			});
			var persistNote = E('div', {'class': 'tc-cut__warn' + (cutPersist ? '' : ' tc-hidden')},
				_('You will need LAN or physical access to undo this — a reboot will not clear it.'));

			// Two clicks, on purpose. Everything else in this app affects one
			// device; this one can take away the path the operator is managing
			// the router through.
			btn = E('button', {'class': 'btn cbi-button-negative'}, _('Cut internet'));
			btn.addEventListener('click', function() {
				if (!cutArmed) {
					cutArmed = true;
					btn.textContent = _('Click again to confirm');
					btn.className = 'btn cbi-button-negative tc-cut__btn--armed';
					cutArmTimer = setTimeout(function() {
						cutDisarm();
						btn.textContent = _('Cut internet');
						btn.className = 'btn cbi-button-negative';
					}, 6000);
					return;
				}
				cutSubmit(true, status);
			});

			cutPanel.appendChild(E('div', {'class': 'tc-cut__row'}, [
				E('span', {'class': 'tc-cut__icon'}, '🌐'),
				E('div', {'class': 'tc-cut__body'}, [
					E('div', {'class': 'tc-cut__controls'}, [
						E('b', {}, _('Cut all internet access')),
						pick.el,
						persistToggle,
						btn, status
					]),
					E('div', {'class': 'tc-cut__hint'},
						_('Devices keep talking to each other and to the router — only the way out is closed. ' +
						  'Traffic is stopped on the way in, so a transparent proxy on the router (podkop, passwall) cannot carry it out either. ' +
						  'Remote access that reaches the router through a LAN host (Tailscale, a tunnel, a jump host) stops working while this is on.')),
					persistNote
				])
			]));
		}

		function refreshCut() {
			callCutStatus().then(renderCut).catch(function() {});
		}
		refreshCut();
		// Slow poll: the remaining-time readout and, more importantly, the
		// live rule check that decides whether this renders as ON at all.
		self._cutTimer = setInterval(function() {
			if (document.hidden) { return; }
			refreshCut();
		}, 10000);

		return E('div', {'class':'cbi-map', 'style':'color:currentColor'}, [
			E('h2', {'style':'color:currentColor'}, _('Traffic Control')),
			E('div', {'class':'cbi-section'}, [
				// 【本仓库改动】整页只剩两段：速率限制卡片（内含设备选择、
				//   目标/共享、速率档位、切断、视图与表格）与下面的数据区。
				//   设备选择原先在卡片之外独占两行、"视图与表格" 又是独立卡片，
				//   三块合起来把数据区推得很低 —— 现全部收进同一张卡片。
				offloadBanner,
				// 【本仓库改动 v0.6.8】概览卡片（含统计条）移到**速率限制之上**。
				//   它回答的是「此刻网络怎么样」，是打开这一页第一件想知道的事；
				//   速率限制是**操作**，操作区放在读数下方才符合「先看后改」。
				//   此前顺序是 速率限制 → 概览 → 表格，等于每次都要先滚过一整张
				//   操作卡片才看得到读数。
				overviewCard,
				rateLimitRow,
				statusDiv,
				extStatsDiv,
				deviceGraphDiv,
				// 「表格与速率」紧贴设备表上方：它调的就是下面这张表的刷新与测速
				tableSpeedBar,
				connsDiv,
				activityDiv
			]),
			E('div', {'id':'tc-version-footer','class':'tc-version-footer'},
				'trafficctl (' + TRAFFICCTL_BUILD + ')')
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleTeardown: function() {
		if (this._timer) { clearInterval(this._timer); this._timer = null; }
		if (this._cutTimer) { clearInterval(this._cutTimer); this._cutTimer = null; }
		this._stopBytesPoll && this._stopBytesPoll();
		// ☰ 档位菜单挂在 document 上的两个监听器，随实例建、随实例摘。
		if (this._speedMenuDocClick) { document.removeEventListener('click', this._speedMenuDocClick); this._speedMenuDocClick = null; }
		if (this._speedMenuDocKey) { document.removeEventListener('keydown', this._speedMenuDocKey); this._speedMenuDocKey = null; }
		if (this._onPopState) { window.removeEventListener('popstate', this._onPopState); this._onPopState = null; }
		// 上联图按容器实宽重绘用的 resize 监听器，同样随实例摘除。
		if (this._onResize) { window.removeEventListener('resize', this._onResize); this._onResize = null; }
		// 「限制」弹层挂在 document.body 上（不在视图树里），故必须自己移除；
		// 两个监听器同理 —— 不摘会在切页后仍在收点击，闭包抓着已移除的 DOM。
		if (this._limitPopupDocClick) { document.removeEventListener('click', this._limitPopupDocClick); this._limitPopupDocClick = null; }
		if (this._limitPopupDocKey) { document.removeEventListener('keydown', this._limitPopupDocKey); this._limitPopupDocKey = null; }
		if (this._limitPopup && this._limitPopup.parentNode) { this._limitPopup.parentNode.removeChild(this._limitPopup); this._limitPopup = null; }
		if (this._graphPopupTimer) { clearInterval(this._graphPopupTimer); this._graphPopupTimer = null; }
		if (this._graphPopup && this._graphPopup.parentNode) { this._graphPopup.parentNode.removeChild(this._graphPopup); this._graphPopup = null; }
		// The overview panel lives inside the view's own tree, so the DOM goes
		// with it — but its sample history is on the view object and would be
		// carried into the next visit, where it would draw a graph with a hole
		// the size of the time spent on another page.
		this._ifHistory = {};
		this._ifBytes = {};
		this._ifMeta = [];
	}
});
