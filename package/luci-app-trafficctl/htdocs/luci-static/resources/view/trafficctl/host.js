'use strict';
'require view';
'require rpc';
'require ui';

// 复用设备表的样式表：详情页的表格、chip、速率配色都沿用同一套变量，
// 单独再写一份会造成两页配色漂移。与 status.js 相同的幂等注入写法。
(function() {
	if (!document.querySelector('link[href*="trafficctl/status.css"]')) {
		var lnk = document.createElement('link');
		lnk.rel = 'stylesheet';
		lnk.type = 'text/css';
		lnk.href = '/luci-static/resources/view/trafficctl/status.css';
		document.head.appendChild(lnk);
	}
})();

/*
 * 单台主机的**实时连接详情页**（本仓库新增）。
 *
 * 入口：概览面板「在线主机」里点击 IP 或主机名。
 * 路由：admin/status/trafficctl/host/<ip>（menu.d 里登记为 wildcard 且**无 title**，
 *       因此不会出现在侧边栏，但仍可直达、可收藏、可后退）。
 *
 * 列与实际数据源（全部来自 trafficctl-device.sh 输出的 connections[]）：
 *
 *   应用      netifyd DPI；未安装该 agent 时无数据，显示 — 并说明原因
 *   协议      proto
 *   线路      proxy 判定（回复元组来自本机 :1234 → 代理）否则为出口接口/直连
 *   外网地址  reply dst —— NAT 之后的源地址；代理流由节点决定，故留空
 *   域名      network.rrdns 反向解析（异步、批量、带缓存）
 *   源端口    sport
 *   目的地址  dst
 *   目的端口  dport
 *   上行速率  两次采样差分 bytes_up
 *   下行速率  两次采样差分 bytes_down
 *   累计上行  bytes_up
 *   累计下行  bytes_down
 *   连接状态  state
 *
 * 「字节计数在 flow offload 下是否可信」是这套列的成立前提，已在本路由器实测：
 * 命中 flowtable 的连接带 [OFFLOAD] 标记，但 /proc/net/nf_conntrack 的
 * packets/bytes 仍在增长（40 MB 下载期间回复方向由 0 涨到 1.1 MB 级），
 * 因此速率与累计列显示真实值，无需降级标注。
 */

var STORAGE_KEY = 'trafficctl_host_opts';

var callDevice = rpc.declare({
	object: 'luci.trafficctl',
	method: 'device',
	params: ['ip', 'proto']
});

var callNetworkRrdnsLookup = rpc.declare({
	object: 'network.rrdns',
	method: 'lookup',
	params: ['addrs', 'timeout', 'limit'],
	expect: { '': {} }
});

// 私有地址不做反向解析：PTR 只可能得到无意义的本地名，还白等一次超时。
var PRIVATE_RE = /^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)/;

function fmtBytes(b) {
	if (b == null || isNaN(b)) return '—';
	if (b < 1024) return b + ' B';
	if (b < 1048576) return (b/1024).toFixed(1) + ' KB';
	if (b < 1073741824) return (b/1048576).toFixed(2) + ' MB';
	return (b/1073741824).toFixed(2) + ' GB';
}

// 输入单位是 字节/秒；输出按比特每秒呈现（与设备表一致）。
function fmtSpeed(bps) {
	if (bps == null || isNaN(bps)) return '—';
	if (bps < 1) return '—';
	var bits = bps * 8;
	if (bits < 1000) return bits.toFixed(0) + ' bit/s';
	if (bits < 1000000) { var k = bits/1000; return (k % 1 === 0 ? k.toFixed(0) : k.toFixed(1)) + ' Kbit/s'; }
	if (bits < 1000000000) { var m = bits/1000000; return (m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)) + ' Mbit/s'; }
	var g = bits/1000000000; return (g % 1 === 0 ? g.toFixed(0) : g.toFixed(2)) + ' Gbit/s';
}

function escHtml(s) {
	return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// 连接的身份键：五元组里除「方向」外都取值。同一目的地址会有多个源端口，
// 因此源端口必须参与，否则两条连接会互相覆盖对方的差分基线。
function connKey(c) {
	return [c.proto, c.dst, c.sport, c.port].join('|');
}

function loadOpts() {
	try { return JSON.parse(window.localStorage.getItem(STORAGE_KEY) || '{}'); }
	catch(e) { return {}; }
}
function saveOpts(o) {
	try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(o)); } catch(e) {}
}
function optRefresh(o) {
	return (o && o.refresh !== undefined) ? o.refresh : 2;
}

// 从请求路径取出目标 IP。层序兜底三层：
//   1. L.env.requestpath —— 派发器给的完整请求段（含 wildcard 捕获段），最可靠；
//   2. L.env.request_args —— 部分版本单独暴露捕获段；
//   3. location.pathname 末段 —— 前两者都拿不到时的最后手段。
function targetIp() {
	var rp = (L.env && L.env.requestpath) || [];
	if (rp.length) return String(rp[rp.length - 1]);
	var args = (L.env && L.env.request_args) || [];
	if (args.length) return String(args[args.length - 1]);
	var segs = String(window.location.pathname || '').split('/').filter(Boolean);
	return segs.length ? segs[segs.length - 1] : '';
}

function isIpv4(s) {
	if (!/^[0-9.]+$/.test(s)) return false;
	var p = String(s).split('.');
	if (p.length !== 4) return false;
	for (var i = 0; i < 4; i++) {
		if (!/^[0-9]+$/.test(p[i])) return false;
		var n = parseInt(p[i], 10);
		if (n > 255) return false;
	}
	return true;
}

return view.extend({
	_timer: null,
	_devTimer: null,
	_rows: [],
	_rdns: {},
	_gen: 0,

	load: function() {
		return Promise.resolve();
	},

	render: function() {
		var self = this;
		var ip = targetIp();

		if (!isIpv4(ip)) {
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, _('Host details')),
				E('div', { 'class': 'alert-message error' }, _('No valid host address in the URL.'))
			]);
		}

		var opts = loadOpts();
		var titleEl  = E('span', { 'class': 'tc-host-title' }, ip);
		var subEl    = E('span', { 'class': 'tc-host-sub tc-c-muted' }, '');
		var statusEl = E('div', { 'class': 'alert-message info' });
		var tableEl  = E('div', { 'class': 'tc-host-table' });

		var refreshPick = mkChipPick([
			{v:'0', l:_('Off')}, {v:'1', l:'1s'}, {v:'2', l:'2s'},
			{v:'5', l:'5s'}, {v:'10', l:'10s'}
		], String(optRefresh(opts)), function(v) {
			var o = loadOpts(); o.refresh = parseInt(v, 10); saveOpts(o);
			self._setupTimer();
			// 从「关」切回非 0 时立刻拉一次，不让用户白等一整个间隔。
			// 必须走 tick()（而不是 query()）：query 是渲染函数，tick 才是
			// 带重入锁的入口，直连它同样会绕过防重入。
			if (optRefresh(o) > 0) tick();
		});

		function mkChipPick(options, currentValue, onChange) {
			var wrapper = E('span', { 'class': 'tc-chips-row' });
			var selected = currentValue;
			var chips = [];
			options.forEach(function(opt) {
				var chip = E('span', { 'class': opt.v === selected ? 'tc-chip tc-chip--active' : 'tc-chip' }, opt.l);
				chip.addEventListener('click', function() {
					selected = opt.v;
					chips.forEach(function(c) { c.className = c._v === selected ? 'tc-chip tc-chip--active' : 'tc-chip'; });
					onChange(opt.v);
				});
				chip._v = opt.v;
				chips.push(chip);
				wrapper.appendChild(chip);
			});
			return wrapper;
		}

		var backLink = E('a', {
			'class': 'tc-host-back',
			'href': L.url('admin/status/trafficctl/status')
		}, '← ' + _('Back to overview'));

		// ── 实时连接表 ────────────────────────────────────────────────
		// 差分基线：键为五元组的 prev[map] = {up, down, t}。
		var prev = {};
		var queryInFlight = false;
		var sortCol = opts.sortCol || 'down', sortDir = opts.sortDir || 'desc';

		function renderTable(rows) {
			var cols = [
				// 用 'App' 而不是 'Application'：msgid 是**全仓库共用**的键，
				// 别的语言包（本例是 nlbwmon）已把 'Application' 译成「应用层」，
				// 同键译文会互相覆盖，我们的表头就会莫名变成 nlbwmon 的用词。
				// 'App' 是本应用既有的 msgid（设备表「应用」列），无冲突。
				{ key:'app',   label:_('App'),         num:false },
				{ key:'proto', label:_('Protocol'),    num:false },
				{ key:'line',  label:_('Line'),        num:false },
				{ key:'wan',   label:_('WAN address'), num:false },
				{ key:'host',  label:_('Domain'),      num:false },
				{ key:'sport', label:_('Source port'), num:true  },
				{ key:'dst',   label:_('Destination'), num:false },
				{ key:'port',  label:_('Dst port'),    num:true  },
				{ key:'up_rate',   label:_('Upload rate'),     num:true },
				{ key:'down_rate', label:_('Download rate'),   num:true },
				{ key:'bytes_up',   label:_('Total upload'),   num:true },
				{ key:'bytes_down', label:_('Total download'), num:true },
				{ key:'state', label:_('Connection state'), num:false }
			];

			var sorted = rows.slice().sort(function(a, b) {
				var av = a[sortCol], bv = b[sortCol];
				if (typeof av === 'number' || typeof bv === 'number') {
					av = Number(av) || 0; bv = Number(bv) || 0;
					return sortDir === 'asc' ? av - bv : bv - av;
				}
				av = String(av == null ? '' : av); bv = String(bv == null ? '' : bv);
				return sortDir === 'asc' ? av.localeCompare(bv) : bv.localeCompare(av);
			});

			var head = E('div', { 'class': 'tr cbi-section-table-titles' }, cols.map(function(c) {
				var arrow = c.key === sortCol ? (sortDir === 'asc' ? ' ▲' : ' ▼') : '';
				var th = E('div', { 'class': 'th', 'data-col': c.key, 'data-num': c.num ? '1' : '0' }, c.label + arrow);
				th.addEventListener('click', function() {
					if (sortCol === c.key) {
						sortDir = sortDir === 'asc' ? 'desc' : 'asc';
					} else {
						sortCol = c.key;
						sortDir = c.num ? 'desc' : 'asc';
					}
					var o = loadOpts(); o.sortCol = sortCol; o.sortDir = sortDir; saveOpts(o);
					renderTable(rows);
				});
				return th;
			}));

			var body = sortCol === 'down' ? sorted : sorted;

			var trs = body.map(function(r) {
				function rateCell(v, cls) {
					return E('div', { 'class': 'td tc-right tc-mono ' + (v > 0 ? cls : 'tc-speed-idle') },
						v == null ? '—' : fmtSpeed(v));
				}
				return E('div', { 'class': 'tr' }, [
					// 应用：netifyd DPI 未运行时无数据。留白而非填「未知」，
					// 并用 tooltip 说明缺的是 agent 而不是这一条连接。
					E('div', { 'class': 'td tc-center' },
						r.app ? E('span', { 'class': 'tc-app-badge' }, escHtml(r.app))
						      : E('span', { 'class': 'tc-c-faint', 'title': _('Needs the netifyd DPI agent, which is not installed on this router.') }, '—')),
					E('div', { 'class': 'td tc-fw-bold tc-c-speed' }, r.proto || ''),
					// 线路：回复元组来自本机代理端口即「代理」，否则是出口接口本身。
					E('div', { 'class': 'td tc-center' }, r.line === 'proxy'
						? E('span', { 'class': 'tc-c-warn tc-fw-bold', 'title': _('Intercepted by the transparent proxy.') }, _('Proxy'))
						: E('span', { 'class': 'tc-c-muted' }, r.oif ? escHtml(r.oif) : _('Direct'))),
					E('div', { 'class': 'td tc-mono' }, r.wan
						? escHtml(r.wan)
						: E('span', { 'class': 'tc-c-faint', 'title': _('Behind the proxy the outgoing address is chosen by the node, so this connection has no external address of its own.') }, '—')),
					E('div', { 'class': 'td' }, r.host
						? escHtml(r.host)
						: E('span', { 'class': 'tc-c-faint' }, self._rdns[r.dst] === undefined && !PRIVATE_RE.test(r.dst)
							? _('resolving…') : '—')),
					E('div', { 'class': 'td tc-right tc-mono' }, String(r.sport || '')),
					E('div', { 'class': 'td tc-mono' }, escHtml(r.dst || '')),
					E('div', { 'class': 'td tc-right tc-mono' }, String(r.port || '')),
					rateCell(r.up_rate, 'tc-c-ok'),
					rateCell(r.down_rate, 'tc-c-speed'),
					E('div', { 'class': 'td tc-right tc-mono' }, fmtBytes(r.bytes_up)),
					E('div', { 'class': 'td tc-right tc-mono' }, fmtBytes(r.bytes_down)),
					E('div', { 'class': 'td tc-fw-bold' + stateClass(r.state) }, escHtml(r.state || ''))
				]);
			});

			while (tableEl.firstChild) tableEl.removeChild(tableEl.firstChild);
			if (!rows.length) {
				tableEl.appendChild(E('p', { 'style': 'color:var(--tc-muted);padding:12px 0' },
					_('No active connections for this host.')));
				return;
			}
			tableEl.appendChild(E('div', { 'class': 'table tc-table' }, [head].concat(trs)));
		}

		function stateClass(s) {
			if (s === 'ESTABLISHED') return ' tc-c-ok';
			if (s === 'TIME_WAIT') return ' tc-c-err';
			if (s === 'CLOSE_WAIT') return ' tc-c-warn';
			return '';
		}

		function refreshRrdns(rows, gen) {
			var seen = {}, need = [];
			rows.forEach(function(r) {
				if (!r.dst || PRIVATE_RE.test(r.dst) || seen[r.dst]) return;
				seen[r.dst] = true;
				if (self._rdns[r.dst] === undefined) need.push(r.dst);
			});
			if (!need.length) return;
			callNetworkRrdnsLookup(need, 5000, need.length).then(function(replies) {
				if (gen !== self._gen) return;
				need.forEach(function(d) {
					self._rdns[d] = (replies && replies[d]) || null;
				});
				renderTable(self._rows);
			}).catch(function() {
				if (gen !== self._gen) return;
				need.forEach(function(d) { self._rdns[d] = null; });
				renderTable(self._rows);
			});
		}

		function applySample(list) {
			var now = Date.now();
			var out = [];
			var alive = {};

			list.forEach(function(c) {
				var k = connKey(c);
				alive[k] = true;
				var up = Number(c.bytes_up) || 0;
				var down = Number(c.bytes_down) || 0;
				var line = c.proxy ? 'proxy' : '';
				// 域名优先取后端已解析的（rDNS 开启时），否则由前端异步补。
				var host = c.host || (self._rdns[c.dst] || '');

				var p = prev[k];
				var upRate = null, downRate = null;
				if (p) {
					var dt = (now - p.t) / 1000;
					if (dt >= 0.5) {
						var du = up - p.up, dd = down - p.down;
						// 计数回绕或连接被复用：丢弃这一拍而不是报负数。
						if (du >= 0 && dd >= 0) {
							upRate = du / dt;
							downRate = dd / dt;
						}
					}
				}
				prev[k] = { up: up, down: down, t: now };

				out.push({
					app: '',
					proto: c.proto || '',
					line: line,
					oif: c.oif || '',
					wan: c.wan || '',
					host: host,
					sport: c.sport || 0,
					dst: c.dst || '',
					port: c.port || 0,
					up_rate: upRate,
					down_rate: downRate,
					bytes_up: up,
					bytes_down: down,
					state: c.state || ''
				});
			});

			// 已消失的连接必须丢掉基线，否则同一五元组被复用时会算出巨大速率。
			Object.keys(prev).forEach(function(k) { if (!alive[k]) delete prev[k]; });

			return out;
		}

		function renderSummary(name, rows) {
			var up = 0, down = 0;
			rows.forEach(function(r) { up += r.bytes_up; down += r.bytes_down; });
			titleEl.textContent = (name && name !== '*') ? name : ip;
			subEl.textContent = ip + (name && name !== '*' ? '' : '') + ' · ' + rows.length + ' ' + _('connections');
			while (statusEl.firstChild) statusEl.removeChild(statusEl.firstChild);
			statusEl.className = 'alert-message info';
			statusEl.appendChild(E('span', {}, [
				document.createTextNode(_('Active connections') + ': '),
				E('b', {}, String(rows.length))
			]));
			statusEl.appendChild(E('span', { 'class': 'tc-sep' }));
			statusEl.appendChild(E('span', {}, [
				document.createTextNode(_('Total upload') + ': '),
				E('b', { 'class': 'tc-mono tc-c-ok' }, fmtBytes(up))
			]));
			statusEl.appendChild(E('span', { 'class': 'tc-sep' }));
			statusEl.appendChild(E('span', {}, [
				document.createTextNode(_('Total download') + ': '),
				E('b', { 'class': 'tc-mono tc-c-speed' }, fmtBytes(down))
			]));
		}

		function query() {
			self._gen++;
			var gen = self._gen;
			return callDevice(ip, '').then(function(data) {
				if (!data || data.error) {
					statusEl.className = 'alert-message error';
					statusEl.textContent = (data && data.error) || _('Unknown error');
					return;
				}
				var rows = applySample(data.connections || []);
				self._rows = rows;
				renderSummary(data.name, rows);
				renderTable(rows);
				refreshRrdns(rows, gen);
			}).catch(function(e) {
				statusEl.className = 'alert-message error';
				statusEl.textContent = '✗ ' + (e.message || e);
			});
		}

		// 防重入：device 这一调用要读完整 conntrack 表并按设备解析，1 秒档位下
		// 若每次都无条件发起，请求会层层堆积、rpcd 不断 fork 子脚本。
		// （与 status.js 同一套做法，本仓库已因这个问题返工过一次。）
		function tick() {
			if (queryInFlight) return;
			if (document.hidden) return;
			queryInFlight = true;
			var p = query();
			(p && p.then ? p : Promise.resolve()).then(unlock, unlock);
		}
		function unlock() { queryInFlight = false; }

		this._setupTimer = function() {
			if (self._timer) { clearInterval(self._timer); self._timer = null; }
			var iv = parseInt(optRefresh(loadOpts()), 10) || 0;
			if (iv > 0) self._timer = setInterval(tick, iv * 1000);
		};

		this._setupTimer();
		// 首帧立即拉取：让表在第一次间隔到来前就有内容，而不是空 2 秒。
		setTimeout(function() { tick(); }, 0);

		return E('div', { 'class': 'cbi-map', 'style': 'color:currentColor' }, [
			E('div', { 'class': 'tc-host-head' }, [
				backLink,
				E('h2', { 'class': 'tc-host-h2' }, [titleEl]),
				E('div', { 'class': 'tc-host-subline' }, subEl)
			]),
			E('div', { 'class': 'tc-host-toolbar' }, [
				E('span', { 'class': 'tc-inline-label' }, _('Refresh') + ':'),
				refreshPick
			]),
			statusEl,
			tableEl,
			E('p', { 'class': 'tc-host-note tc-c-faint' },
				_('Every row is one live conntrack entry. Upload is what this host sent; download is what it received. Rates are computed between two samples.'))
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleTeardown: function() {
		if (this._timer) { clearInterval(this._timer); this._timer = null; }
	}
});
