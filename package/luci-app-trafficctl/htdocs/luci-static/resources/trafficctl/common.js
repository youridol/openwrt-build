'use strict';
'require baseclass';
'require rpc';

/*
 * trafficctl 各页面共用的基础件（本仓库新增）。
 *
 * 为什么需要这个模块：本包的页面级 tab 各自是一个独立视图
 * （status / settings / host / portfw），而它们都要用同一套 rpc 方法、
 * 同一份 localStorage 选项、同一组「开关 / chip / 折叠卡片」控件。此前这些
 * 定义写在 status.js 里，被复制到各视图，再要新增设置页就会出现更多份
 * —— 多份各自漂移，表现是同一个开关在不同页面行为不一致。故集中到这里。
 *
 * 加载方式：LuCI 的 require 把模块名的 `.` 换成 `/` 去 resources/ 下取，
 * 故视图里的 `'require trafficctl/common'` 对应
 * /luci-static/resources/trafficctl/common.js。已核对 luci.js 的 require()
 * 实现：url = base_url + name.replace(/\./g, '/') + '.js'。
 *
 * 导出**必须是 baseclass 子类**：LuCI 的前端 require 在 luci.js 里对工厂
 * 返回值做 `Class.isSubclass(_class)` 断言，普通对象会直接抛
 * `TypeError: "trafficctl/common" factory yields invalid constructor`
 * 并令整个页面加载失败。require 返回的又是 `new _class()` 的**实例**，
 * 故调用方写 `T.fmtBytes(...)` 这种实例方法调用是成立
 * （定义在原型上，实例可访问）。
 */

var STORAGE_KEY = 'trafficctl_opts';
var RECENT_KEY = 'trafficctl_recent';
var MAX_RECENT = 6;

// 路由器级默认值（可被管理员经 UCI 下发）。浏览器自己的选择仍优先生效；
// 这里只决定「新会话从哪开始」。
// 【本仓库改动】pollInterval 默认 1（上游 2）：本页核心用途是实时监看，
//   1 秒档位是最直观的起步值。代价是路由器每秒一次 conntrack 读取 ——
//   故 status.js 的三处字节轮询都加了防重入闸（单次 RPC 实测最坏可达 1.9s，
//   无闸时 1 秒档位实测 30 秒内重叠 3 次）。改这个值前先确认防重入还在。
var siteDefaults = { pollInterval: 1, avgWindow: 15, refreshInterval: 5 };

// ── rpc ───────────────────────────────────────────────────────────────
function decl(method, params, expect) {
	var spec = { object: 'luci.trafficctl', method: method };
	if (params) spec.params = params;
	if (expect) spec.expect = expect;
	return rpc.declare(spec);
}

// ── 选项存取（per-browser）────────────────────────────────────────────
function loadOpts() {
	try { return JSON.parse(window.localStorage.getItem(STORAGE_KEY) || '{}'); }
	catch(e) { return {}; }
}
function saveOpts(o) {
	try { window.localStorage.setItem(STORAGE_KEY, JSON.stringify(o)); } catch(e) {}
}
// 0 在这里是合法选择（「不轮询」），故用显式 undefined 判断而非真值判断。
function optPoll(o) {
	return (o && o.pollInterval !== undefined) ? o.pollInterval : siteDefaults.pollInterval;
}
function optWindow(o) {
	return (o && o.avgWindow) ? o.avgWindow : siteDefaults.avgWindow;
}
// 整表自动刷新间隔（秒），0 = 关闭。默认值取自路由器级配置。
function optRefresh(o) {
	return (o && o.refresh !== undefined) ? o.refresh : siteDefaults.refreshInterval;
}

// ── 最近访问设备 ──────────────────────────────────────────────────────
function getRecentDevices() {
	try {
		var stored = JSON.parse(window.localStorage.getItem(RECENT_KEY) || '[]');
		return stored.map(function(r) { return typeof r === 'string' ? { ip: r, name: r } : r; });
	} catch(e) { return []; }
}
function saveRecentDevices(arr) {
	try { window.localStorage.setItem(RECENT_KEY, JSON.stringify(arr)); } catch(e) {}
}
function addRecentDevice(ip, name) {
	var recent = getRecentDevices();
	var existing = recent.filter(function(r) { return (r.ip || r) === ip; })[0];
	recent = recent.filter(function(r) { return (r.ip || r) !== ip; });
	recent.unshift({ ip: ip, name: name || (existing && existing.name) || ip });
	if (recent.length > MAX_RECENT) recent.length = MAX_RECENT;
	saveRecentDevices(recent);
}

// ── 格式化 ────────────────────────────────────────────────────────────
function fmtBytes(b) {
	if (b == null || isNaN(b)) return '—';
	if (b < 1024) return b + ' B';
	if (b < 1048576) return (b/1024).toFixed(1) + ' KB';
	if (b < 1073741824) return (b/1048576).toFixed(2) + ' MB';
	return (b/1073741824).toFixed(2) + ' GB';
}
function fmtSpeed(bps) {
	if (!bps || bps < 1) return '—';
	var bits = bps * 8;
	if (bits < 1000) return bits.toFixed(0) + ' bit/s';
	if (bits < 1000000) { var k = bits/1000; return (k % 1 === 0 ? k.toFixed(0) : k.toFixed(1)) + ' Kbit/s'; }
	if (bits < 1000000000) { var m = bits/1000000; return (m % 1 === 0 ? m.toFixed(0) : m.toFixed(1)) + ' Mbit/s'; }
	var g = bits/1000000000; return (g % 1 === 0 ? g.toFixed(0) : g.toFixed(2)) + ' Gbit/s';
}
function fmtRate(kbit) {
	if (!kbit || kbit <= 0) return '—';
	var mbit = kbit / 1000;
	if (mbit >= 1) return (mbit % 1 === 0 ? mbit.toFixed(0) : mbit.toFixed(1)) + ' Mbit/s';
	return kbit + ' kbit/s';
}
function escHtml(s) {
	return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// ── 视图层小控件 ──────────────────────────────────────────────────────
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
function mkLabel(t) {
	return E('span', { 'class': 'tc-inline-label' }, t);
}
function mkChipPick(options, currentValue, onChange) {
	var wrapper = E('span', { 'style': 'display:inline-flex;flex-wrap:wrap;gap:2px;align-items:center' });
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
	return {
		el: wrapper,
		getValue: function() { return selected; },
		setValue: function(v) {
			selected = v;
			chips.forEach(function(c) { c.className = c._v === v ? 'tc-chip tc-chip--active' : 'tc-chip'; });
		}
	};
}
function sep() { return E('span', { 'class': 'tc-sep' }); }
function sectionLabel(t) { return E('div', { 'class': 'tc-section-label' }, t); }

/*
 * 可折叠卡片。默认展开；折叠态不持久化 —— 记住折叠会把「用户收起过一次」
 * 变成「以后每次都看不到设置」，观感就是设置项消失了。
 *
 * loader 作为构造参数传入而不是返回后再挂：初始即展开时内部会立刻触发首次
 * 展开，若沿用「返回后再赋 onFirstOpen」的写法，回调此刻还没挂上，
 * 懒加载永不执行、内容区空白。
 */
function mkCollapsible(title, content, startOpen, loader) {
	var open = (startOpen === undefined) ? true : !!startOpen;
	var body = E('div', { 'class': 'tc-collapsible-body' + (open ? '' : ' tc-hidden') });
	if (content) body.appendChild(content);
	var arrow = E('span', { 'class': 'tc-collapse-arrow' }, open ? '▾' : '▸');
	var label = sectionLabel(title);
	label.classList.add('tc-collapsible-head');
	label.appendChild(arrow);
	var el = E('div', { 'class': 'tc-card' + (open ? ' tc-card--open' : '') }, [label, body]);
	var api = { label: label, body: body, el: el, _opened: false, _loader: loader };
	function setOpen(v) {
		open = !!v;
		body.classList.toggle('tc-hidden', !open);
		el.classList.toggle('tc-card--open', open);
		arrow.textContent = open ? '▾' : '▸';
		if (open && !api._opened) { api._opened = true; if (api._loader) api._loader(body); }
	}
	label.addEventListener('click', function() { setOpen(!open); });
	label._tcSetOpen = setOpen;
	if (open) setOpen(true);
	return api;
}

// 「加载中…」占位，各懒加载区块统一用它开场。
function mkLoading() {
	return E('span', { 'style': 'font-size:12px;color:var(--tc-muted)' }, _('Loading…'));
}

// 懒加载失败的统一收尾：把占位替换成错误文本，不要静默留白。
function showLoadError(statusSpan, e) {
	statusSpan.textContent = '✗ ' + ((e && e.message) || e);
	statusSpan.style.color = 'var(--tc-err)';
}

/*
 * 防重入轮询。summary 实测约 1.9 秒，而档位可设 1 秒；若用
 * `setInterval(runQuery, …)` 这种不看上一拍是否回来的写法，请求会层层堆积、
 * rpcd 不断 fork 子脚本、路由器 load 飙升，页面反而卡住甚至 XHR 超时。
 *
 * fn 必须返回 promise —— 锁在**请求真正结束**后才复位；若 fn 立刻返回，
 * 锁形同虚设。返回 { start, stop, tick }。
 */
function mkPoll(fn, intervalFn) {
	var timer = null;
	var inFlight = false;
	function unlock() { inFlight = false; }
	function tick() {
		if (inFlight || document.hidden) return;
		inFlight = true;
		var p = fn();
		(p && typeof p.then === 'function' ? p : Promise.resolve()).then(unlock, unlock);
	}
	return {
		start: function() {
			this.stop();
			var iv = parseInt(intervalFn(), 10) || 0;
			if (iv > 0) timer = setInterval(tick, iv * 1000);
		},
		stop: function() { if (timer) { clearInterval(timer); timer = null; } },
		tick: tick
	};
}

return baseclass.extend({
	STORAGE_KEY: STORAGE_KEY,
	RECENT_KEY: RECENT_KEY,
	MAX_RECENT: MAX_RECENT,
	siteDefaults: siteDefaults,

	// rpc
	trafficctl:      decl('summary', null, { result: [] }),
	device:          decl('device', ['ip', 'proto']),
	bytes:           decl('bytes', null, { result: [] }),
	ifaces:          decl('ifaces', null, { result: [] }),
	block:           decl('block', ['ip', 'label']),
	unblock:         decl('unblock', ['ip', 'label']),
	macfilterAdd:    decl('macfilter_add', ['ip']),
	macfilterRemove: decl('macfilter_remove', ['ip']),
	ratelimit:       decl('ratelimit', ['ip', 'rate_kbit', 'label', 'mode', 'rate_kbit_up']),
	ratelimitStats:  decl('ratelimit_stats', null, { result: [] }),
	subnets:         decl('subnets', null, { result: [] }),
	shapeAdd:        decl('shape_add', ['ip', 'rate_kbit', 'label', 'rate_kbit_up']),
	shapeRemove:     decl('shape_remove', ['ip', 'label']),
	shapeStats:      decl('shape_stats', null, { result: [] }),
	netifyList:      decl('netify_list', null, { result: [] }),
	nameSet:         decl('name_set', ['ip', 'name']),
	loggingGet:      decl('logging_config_get'),
	loggingSet:      decl('logging_config_set', ['enabled', 'log_file', 'max_lines', 'syslog',
	                                             'log_blocks', 'log_ratelimits', 'log_shapes',
	                                             'log_config', 'persist_rules']),
	newDeviceGet:    decl('newdevice_config_get'),
	newDeviceSet:    decl('newdevice_config_set', ['enabled', 'limit_kbit', 'limit_mode']),
	cutStatus:       decl('cut_status'),
	cutSet:          decl('cut_set', ['active', 'duration', 'persist']),
	activityLog:     decl('activity_log', ['lines']),
	version:         decl('version'),
	configGet:       decl('config_get'),
	configSet:       decl('config_set', ['enabled', 'default_mode', 'sw', 'hw',
	                                     'poll_interval', 'avg_window', 'refresh_interval']),
	networkRrdnsLookup: rpc.declare({
		object: 'network.rrdns',
		method: 'lookup',
		params: ['addrs', 'timeout', 'limit'],
		expect: { '': {} }
	}),

	// 选项
	loadOpts: loadOpts, saveOpts: saveOpts,
	optPoll: optPoll, optWindow: optWindow, optRefresh: optRefresh,
	getRecentDevices: getRecentDevices, saveRecentDevices: saveRecentDevices,
	addRecentDevice: addRecentDevice,

	// 格式化
	fmtBytes: fmtBytes, fmtSpeed: fmtSpeed, fmtRate: fmtRate,
	escHtml: escHtml,

	// 控件
	mkToggle: mkToggle, mkLabel: mkLabel, mkChipPick: mkChipPick,
	sep: sep, sectionLabel: sectionLabel, mkCollapsible: mkCollapsible,
	mkLoading: mkLoading, showLoadError: showLoadError, mkPoll: mkPoll
});
