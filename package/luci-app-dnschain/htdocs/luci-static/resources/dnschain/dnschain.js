/* =====================================================================
 * luci-app-dnschain — Tab 控制器
 *
 * 为什么用 JS 分组而不是 CBI 原生 tab：
 *
 *   CBI 的 tab 需要为每个 tab 建独立 Map 文件，页面加载时要 parse 全部
 *   Map —— 每个 Map 都会跑一遍自检采集（实测单次 660ms），反而更慢。
 *   而且跨 Map 无法一次保存，配置会被拆散。
 *
 *   所以用「单张 CBI 表单 + 前端分组」：服务端仍是一次渲染，
 *   前端把 section 按标题归组，点击 tab 只切显示，零网络请求。
 *
 * 归组依据：服务端在页面里输出一个 <span data-dc-meta>，
 * 带两个 JSON：{ section 标题 => tab id } 与 { tab id => 显示名 }。
 * 见 general.lua 的 emit_tab_meta()。
 *
 * 为什么按标题匹配而不是给 section 打属性：
 *   CBI 的 tsection.htm / nsection.htm 只输出固定结构，不读 section 上的
 *   自定义字段。覆盖模板会把 LuCI 内部结构复制进本包，上游升级易冲突。
 *   按标题匹配的代价是「改标题要同步映射表」，比复制模板稳定得多。
 * ===================================================================== */

(function () {
	'use strict';

	var STORAGE_KEY = 'dnschain.activeTab';
	var TAB_ORDER = ['overview', 'resolve', 'split', 'proxy', 'dhcp', 'diag'];

	var meta = null;

	function readMeta() {
		var holder = document.querySelector('[data-dc-meta]');
		if (!holder) return null;
		var out = { sectionTab: {}, labels: {} };
		try {
			out.sectionTab = JSON.parse(holder.getAttribute('data-dc-section-tab') || '{}');
		} catch (e) { /* 保持空 */ }
		try {
			out.labels = JSON.parse(holder.getAttribute('data-dc-labels') || '{}');
		} catch (e) { /* 保持空 */ }
		return out;
	}

	/**
	 * 找到页面上所有 CBI section 容器。
	 *
	 * 不同主题的 DOM 结构不同，所以用「同时含 h3 与 .cbi-section-node 的
	 * 最近公共父元素」来定位，不依赖具体标签名。
	 * shadcn 主题下是 div.cbi-section；经典主题下是 fieldset。
	 */
	function findSections() {
		var result = [];
		var h3s = document.querySelectorAll('.cbi-section > h3, fieldset > legend');

		for (var i = 0; i < h3s.length; i++) {
			var titleEl = h3s[i];
			var box = titleEl.parentNode;
			if (!box) continue;
			/* 排除 CBI 的 tab 标题（本页不用原生 tab，但保险） */
			if (box.classList && box.classList.contains('cbi-section-node')) continue;
			var title = (titleEl.textContent || '').trim();
			if (!title) continue;
			result.push({ el: box, title: title, tab: meta.sectionTab[title] || null });
		}
		return result;
	}

	function countBadges(el) {
		return el.querySelectorAll('.dc-badge--bad').length;
	}

	/**
	 * 取 tab 的纯标签文本（不含徽标数字）。
	 *
	 * 徽标是按钮的子元素，textContent 会把数字一起读进来，
	 * 实测 tab 显示成「诊断1」。用第一个文本节点更准。
	 */
	function tabLabel(btn) {
		for (var i = 0; i < btn.childNodes.length; i++) {
			var n = btn.childNodes[i];
			if (n.nodeType === 3 && n.textContent.trim()) return n.textContent.trim();
		}
		return (btn.textContent || '').replace(/\d+$/, '').trim();
	}

	function buildBar(present, counts) {
		var bar = document.createElement('div');
		bar.className = 'dc-tabs';
		bar.setAttribute('role', 'tablist');

		TAB_ORDER.forEach(function (id) {
			if (present.indexOf(id) < 0) return;

			var btn = document.createElement('button');
			btn.type = 'button';
			btn.className = 'dc-tab';
			btn.setAttribute('role', 'tab');
			btn.setAttribute('data-tab', id);
			btn.setAttribute('aria-selected', 'false');
			btn.textContent = meta.labels[id] || id;

			var bad = counts[id] || 0;
			if (bad > 0) {
				var badge = document.createElement('span');
				badge.className = 'dc-tab__badge';
				badge.textContent = String(bad);
				badge.title = bad + ' 项异常';
				btn.appendChild(badge);
			}

			btn.addEventListener('click', function () { activate(id); });
			bar.appendChild(btn);
		});

		return bar;
	}

	var sections = [];

	function activate(id) {
		sections.forEach(function (sec) {
			/* 未归组的 section 始终显示 —— 避免新增 section 后莫名消失 */
			if (!sec.tab) {
				sec.el.hidden = false;
				return;
			}
			sec.el.hidden = (sec.tab !== id);
		});

		var tabs = document.querySelectorAll('.dc-tab');
		for (var i = 0; i < tabs.length; i++) {
			tabs[i].setAttribute('aria-selected',
				tabs[i].getAttribute('data-tab') === id ? 'true' : 'false');
		}

		try { localStorage.setItem(STORAGE_KEY, id); } catch (e) { /* 忽略 */ }
	}

	function init() {
		meta = readMeta();
		if (!meta) return;

		/* 收起承载元数据的空 section：CBI 会给它套 .cbi-section 与
		 * .cbi-value 两层，实测占 11px，在 tab 栏上方留一段空白。
		 * CSS 里用 :has() 做了声明式处理，但老 WebKit 不支持，
		 * 这里用 JS 兜底（更可靠，也不依赖选择器支持）。 */
		var holder = document.querySelector('[data-dc-meta]');
		if (holder) {
			var box = holder.closest('.cbi-section');
			if (box) box.style.display = 'none';
			else if (holder.parentElement) holder.parentElement.style.display = 'none';
		}

		sections = findSections();
		if (sections.length === 0) return;

		var present = [];
		var counts = {};

		sections.forEach(function (sec) {
			if (!sec.tab) return;
			if (present.indexOf(sec.tab) < 0) present.push(sec.tab);
			counts[sec.tab] = (counts[sec.tab] || 0) + countBadges(sec.el);
		});

		if (present.length === 0) return;

		var bar = buildBar(present, counts);

		/* 插到第一个已归组 section 之前 */
		var first = null;
		for (var i = 0; i < sections.length; i++) {
			if (sections[i].tab) { first = sections[i]; break; }
		}
		if (first && first.el.parentNode) {
			first.el.parentNode.insertBefore(bar, first.el);
		}

		var saved = null;
		try { saved = localStorage.getItem(STORAGE_KEY); } catch (e) { saved = null; }
		var initial = (saved && present.indexOf(saved) >= 0) ? saved : present[0];
		activate(initial);
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', init);
	} else {
		init();
	}
})();
