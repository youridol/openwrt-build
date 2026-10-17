'use strict';
'require view';
'require trafficctl/common as T';

/*
 * 【必须手动注入 status.css】
 * LuCI 只为**视图模块**自动加载与之同名的样式：本视图是 trafficctl/settings.js，
 * 对应的 trafficctl/settings.css 并不存在，因此 status.css **不会**被自动带上。
 * 不注入的后果是页面上所有 tc-* 类失效 —— 卡片没有边框与内边距、
 * chip 没有底色、折叠箭头错位、各档位挤成一片。
 * 实测未注入时 <link> 只剩 /luci-static/shadcn/main.css。
 * 与 status.js / host.js / portfw.js 保持同一做法。
 */
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
 * 设置页（本仓库新增，页面级 tab「设置」）。
 *
 * 为什么单独成页：这些设置原先挤在设备页中部（实测该面板 580px），把
 * 「看谁在占带宽」这个主任务压到折叠区以下；而它们又都是**一次性配置**，
 * 不需要和设备表抢注意力。拆成独立 tab 后，设备页只剩设备相关的东西。
 *
 * 分区（四张卡片，按「多久动一次」排序）：
 *   表格与速率   轮询/窗口/方法/可见列 —— 最常调
 *   流量卸载     software / hardware offload
 *   新设备默认值  新设备限速
 *   日志与持久化  日志开关与分类、持久化规则
 */

var callConfigGet = T.configGet;
var callConfigSet = T.configSet;
var callLoggingGet = T.loggingGet;
var callLoggingSet = T.loggingSet;
var callNewDeviceGet = T.newDeviceGet;
var callNewDeviceSet = T.newDeviceSet;

return view.extend({
	load: function() { return Promise.resolve(); },

	render: function() {
		// ── 表格与速率 ────────────────────────────────────────────────
		// 【本仓库改动】这组档位（轮询 / 窗口 / 方法 / 刷新 + 路由端默认值）
		//   已迁到**设备页**，显示在设备列表上方 —— 它们直接决定那张表怎么刷新、
		//   速率怎么算，放在设备表旁边比放在设置页更合理。此处不再构建。
		// ── 流量卸载 ──────────────────────────────────────────────────
		var offloadCard = T.mkCollapsible(_('Flow Offload'), null, true, function(body) { loadOffloadUI(body); });

		function loadOffloadUI(container) {
			var statusSpan = T.mkLoading();
			container.appendChild(statusSpan);

			callConfigGet().then(function(cfg) {
				while (container.firstChild) container.removeChild(container.firstChild);

				var saveStatus = E('span', { 'class': 'tc-save-status' });
				var saveTimer = null;
				var swCb, hwCb;

				function doSave() {
					if (saveTimer) clearTimeout(saveTimer);
					saveTimer = setTimeout(function() {
						saveStatus.textContent = _('Applying…');
						saveStatus.style.color = 'var(--tc-muted)';
						callConfigSet(undefined, undefined, swCb.checked, hwCb.checked).then(function(res) {
							saveStatus.textContent = (res && res.ok) ? '✓ ' + _('Applied — firewall reloading') : '✗';
							saveStatus.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
						}).catch(function() {
							saveStatus.textContent = '✗';
							saveStatus.style.color = 'var(--tc-err)';
						});
					}, 400);
				}

				var modeLabels = {
					'none':              ['⊘', _('No offload'),       'var(--tc-muted)'],
					'software':          ['◑', _('Software offload'), 'var(--tc-speed)'],
					// tctl_get_offload_mode 用 flowtable counter 标志细分软件卸载，
					// 该值也会走到这里；缺条目时徽章会退化成 '?' + 原始字符串。
					'software-counter':  ['◑', _('Software offload'), 'var(--tc-speed)'],
					'hardware-counter':  ['●', _('Hardware offload'), 'var(--tc-warn)'],
					'hardware':          ['●', _('Hardware offload'), 'var(--tc-warn)']
				};
				var ml = modeLabels[cfg.offload_mode] || ['?', cfg.offload_mode, 'var(--tc-muted)'];
				var modeBadge = E('div', {'style':'margin-bottom:10px;font-size:12px'}, [
					E('span', {'style':'color:'+ml[2]+';font-size:15px;margin-right:4px'}, ml[0]),
					E('span', {'style':'color:var(--tc-muted)'}, _('Current mode: ')),
					E('b', {}, ml[1])
				]);

				var swToggleEl = T.mkToggle('tc-offload-sw', _('Software flow offload'), cfg.sw, function() {
					hwCb.disabled = !swCb.checked;
					if (!swCb.checked) { hwCb.checked = false; }
					doSave();
				});
				swCb = swToggleEl.querySelector('input');
				var swDesc = E('div', {'class':'tc-offload-desc'},
					_('Accelerates routing in the kernel via nftables flowtable. Speed monitoring and traffic shaping work normally.'));

				var hwToggleEl = T.mkToggle('tc-offload-hw', _('Hardware flow offload'), cfg.hw, doSave);
				hwCb = hwToggleEl.querySelector('input');
				if (!cfg.sw) hwCb.disabled = true;
				var hwDesc = E('div', {'class':'tc-offload-desc'},
					_('Offloads routing to the hardware engine (PPE/NPU). Requires software offload. ' +
					  '⚠ On many platforms (e.g. Mediatek Filogic) the driver does not report byte counters back to the kernel — real-time speed monitoring will show zero.'));

				// 【本仓库改动】原来每个开关与它的说明各占一行，共 5 行（实测 173px）。
				//   说明是长句、开关是短控件，两者同处一行并不会互相挤压，
				//   故改为「开关 + 说明」同一行，说明占剩余宽度。行数 5 → 3。
				swDesc.style.flex = '1';
				swDesc.style.minWidth = '0';
				hwDesc.style.flex = '1';
				hwDesc.style.minWidth = '0';

				container.appendChild(modeBadge);
				container.appendChild(E('div', {'class':'tc-offload-row'}, [swToggleEl, swDesc, saveStatus]));
				container.appendChild(E('div', {'class':'tc-offload-row tc-offload-row--hw'}, [hwToggleEl, hwDesc]));
			}).catch(function(e) { T.showLoadError(statusSpan, e); });
		}

		// ── 新设备默认值 ──────────────────────────────────────────────
		var newDevCard = T.mkCollapsible(_('New Device Defaults'), null, true, function(body) { loadNewDeviceUI(body); });

		function loadNewDeviceUI(container) {
			var statusSpan = T.mkLoading();
			container.appendChild(statusSpan);

			callNewDeviceGet().then(function(cfg) {
				while (container.firstChild) container.removeChild(container.firstChild);

				var saveStatus = E('span', { 'class': 'tc-save-status' });
				var hint = E('div', {'style':'font-size:11px;color:var(--tc-muted);margin-top:6px'});
				var modePick = null;
				var saveTimer = null;

				// 基线大小要显式给出而不是隐含：它正是「不会把整个 LAN 限速」
				// 的依据，操作者据此能分辨台账是空的还是有内容。
				function renderHint(c) {
					var kbit = parseInt(rateInput.value, 10);
					if (enabledToggle.querySelector('input').checked && (!kbit || kbit <= 0)) {
						hint.textContent = _('Set a rate above 0 — with no rate this does nothing.');
						hint.style.color = 'var(--tc-warn)';
						return;
					}
					hint.style.color = 'var(--tc-muted)';
					if (c && c.seeded) {
						hint.textContent = _('Devices already known:') + ' ' + (c.seen_count || 0) +
							' — ' + _('these are never limited by this setting.');
					} else {
						hint.textContent = _('No baseline recorded yet. It is taken from the current leases when you switch this on.');
					}
				}

				function doSave() {
					if (saveTimer) clearTimeout(saveTimer);
					saveTimer = setTimeout(function() {
						saveStatus.textContent = _('Saving…');
						saveStatus.style.color = 'var(--tc-muted)';
						var kbit = parseInt(rateInput.value, 10);
						if (isNaN(kbit) || kbit < 0) kbit = 0;
						callNewDeviceSet(
							enabledToggle.querySelector('input').checked,
							kbit,
							modePick.getValue()
						).then(function(res) {
							saveStatus.textContent = (res && res.ok) ? '✓' : '✗';
							saveStatus.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
							if (res && res.ok) callNewDeviceGet().then(renderHint).catch(function() {});
						}).catch(function() {
							saveStatus.textContent = '✗';
							saveStatus.style.color = 'var(--tc-err)';
						});
					}, 400);
				}

				var enabledToggle = T.mkToggle('tm-nd-enabled', _('Limit new devices'), cfg.enabled, function() {
					renderHint(cfg);
					doSave();
				});

				var rateInput = E('input', {
					'type': 'number', 'min': '0',
					'class': 'tc-input tc-input--num',
					'value': cfg.limit_kbit || 0,
					'placeholder': _('kbit/s')
				});
				rateInput.addEventListener('change', function() { renderHint(cfg); doSave(); });

				modePick = T.mkChipPick([
					{ v: 'limiter', l: _('Limiter') },
					{ v: 'shaper', l: _('Shaper') }
				], cfg.limit_mode || 'limiter', doSave);

				// 全部控件同处一行：开关 + 速率输入 + 单位 + 模式 + 保存状态。
				// 原先折成 2 行是因为旧容器用 column-count:2 把卡片压成半宽；
				// 改为 grid 后卡片宽度恢复，一行放得下（实测 36px → 22px）。
				container.appendChild(E('div', {'class':'tc-log-row'}, [
					enabledToggle, T.mkLabel(_('Rate')), rateInput, T.mkLabel(_('kbit/s')),
					modePick.el, saveStatus
				]));
				container.appendChild(hint);
				container.appendChild(E('div', {'style':'font-size:11px;color:var(--tc-muted);margin-top:4px'},
					_('Applied once, the first time a device appears on the network. A device that already has a limit is left alone.')));

				renderHint(cfg);
			}).catch(function(e) { T.showLoadError(statusSpan, e); });
		}

		// ── 日志与持久化 ──────────────────────────────────────────────
		var loggingCard = T.mkCollapsible(_('Logging & Persistence'), null, true, function(body) { loadLoggingUI(body); });
		// 也是宽卡片：它有两组开关（3 + 5），半宽下照样是两行，并不会省空间；
		// 而放在最后一张时若不占整行，grid 会在右侧留一个空单元格。
		loggingCard.el.classList.add('tc-card--wide');

		function loadLoggingUI(container) {
			var statusSpan = T.mkLoading();
			container.appendChild(statusSpan);

			callLoggingGet().then(function(cfg) {
				while (container.firstChild) container.removeChild(container.firstChild);

				var saveStatus = E('span', { 'class': 'tc-save-status' });
				var saveTimer = null;
				var doSave = function() {
					if (saveTimer) clearTimeout(saveTimer);
					saveTimer = setTimeout(function() {
						saveStatus.textContent = _('Saving…');
						saveStatus.style.color = 'var(--tc-muted)';
						callLoggingSet(
							container.querySelector('#tm-log-enabled').checked,
							null, null,
							container.querySelector('#tm-log-syslog').checked,
							container.querySelector('#tm-log-blocks').checked,
							container.querySelector('#tm-log-ratelimits').checked,
							container.querySelector('#tm-log-shapes').checked,
							container.querySelector('#tm-log-config').checked,
							container.querySelector('#tm-persist-rules').checked
						).then(function(res) {
							saveStatus.textContent = (res && res.ok) ? '✓' : '✗';
							saveStatus.style.color = (res && res.ok) ? 'var(--tc-ok)' : 'var(--tc-err)';
						}).catch(function() {
							saveStatus.textContent = '✗';
							saveStatus.style.color = 'var(--tc-err)';
						});
					}, 400);
				};

				var logEnabled = T.mkToggle('tm-log-enabled', _('Logging'), cfg.enabled, doSave);
				var logSyslog = T.mkToggle('tm-log-syslog', _('Syslog'), cfg.syslog, doSave);
				var persistRules = T.mkToggle('tm-persist-rules', _('Persist rules'), cfg.persist_rules, doSave);

				var logBlocks = T.mkToggle('tm-log-blocks', _('Blocks'), cfg.log_blocks, doSave);
				var logRatelimits = T.mkToggle('tm-log-ratelimits', _('Ratelimits'), cfg.log_ratelimits, doSave);
				var logShapes = T.mkToggle('tm-log-shapes', _('Shapes'), cfg.log_shapes, doSave);
				var logConfig = T.mkToggle('tm-log-config', _('Config'), cfg.log_config, doSave);

				// 【本仓库改动】「日志分类」原先独占一行（标签 42px 高），
				//   而它只是一个分组标题。改为与那 4 个分类开关同一行，
				//   标签在前、开关随后 —— 一行放下，高度 42 → 22。
				//   v0.7.0 起「Telegram」分类开关随 Telegram 全链路一并移除：
				//   该分类只标记由 Telegram 触发的操作，来源没了就是死开关。
				container.appendChild(E('div', {'class':'tc-log-row'}, [logEnabled, logSyslog, persistRules, saveStatus]));
				container.appendChild(E('div', {'class':'tc-log-row', 'style':'margin-top:6px'}, [
					E('span', {'class':'tc-inline-label'}, _('Log categories')),
					logBlocks, logRatelimits, logShapes, logConfig
				]));
			}).catch(function(e) { T.showLoadError(statusSpan, e); });
		}

		// 「表格与速率」已迁回设备页，故本页不再有那组档位，也不再需要
		// 「已保存到设备页」的提示 —— 剩下三张卡片各自带保存状态。
		return E('div', {'class':'cbi-map'}, [
			E('h2', {}, _('Settings')),
			E('div', {'class':'cbi-section'}, [
				E('div', {'class':'tc-settings-page-head'}, [
					E('span', {'class':'tc-settings-hint'}, _('changes are saved automatically'))
				]),
				E('div', {'class':'tc-settings-body'}, [
					offloadCard.el,
					newDevCard.el,
					loggingCard.el
				])
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null,

	handleTeardown: function() {}
});
