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

	/*
	 * tab 顺序。
	 *
	 * 顺序即阅读顺序，按「先看结论、再管配置、最后动手」排：
	 *   概览与诊断（结论 + 解析链路 + 实时诊断链路 + 指标 + 组件状态
	 *              + 自检 20 项 + 操作按钮）   ← v0.15.0 合并
	 *   域名（自定义列表 + 判定链路 + 改道状态）
	 *   解析 / 分流 / 代理 / DHCP（配置）
	 *
	 * v0.15.0 按用户要求把「诊断」并入「概览」：
	 *   两者本就同源（结论徽标与 20 项表格都来自同一次 selftest），
	 *   拆成两个 tab 时用户要来回切才能把「一句话结论」与「逐项证据」对上。
	 *   合并后 tab 由 7 个减为 6 个。
	 *
	 * 「域名」紧跟概览而不是排在配置区中间：
	 *   它同时承担「看」和「配」两件事（判定链路图与状态导图都是只读诊断），
	 *   放到「代理」后面会让用户以为它只是又一张配置表。
	 */
	var TAB_ORDER = ['status', 'domains', 'upstream', 'lists'];

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
			if (!box.classList) continue;
			if (box.classList.contains('cbi-section-node')) continue;
			var title = (titleEl.textContent || '').trim();
			if (!title) continue;
			result.push({ el: box, title: title, tab: meta.sectionTab[title] || null });
		}
		return result;
	}

	function countBadges(el) {
		/* 只统计「需要用户处理」的异常徽标。
		 *
		 * ⚠️ 必须排除分诊结果表里的红徽标（v0.16.2 修）。
		 *
		 *   分诊表用 dc-badge--bad 表示「这个目标两种链路都不通」——
		 *   那是**客观观测结果**，不是本页配置有错，用户也不需要
		 *   去修什么（下一轮分诊会自动重试）。
		 *
		 *   实测问题：分诊表里有 10 条 dead，tab 徽标就显示「10」，
		 *   看上去像「有 10 处配置错误」。这会让用户误以为页面坏了。
		 *
		 *   判据：分诊表的行用 data-dc-triage 标记，跳过其内部徽标。
		 */
		var all = el.querySelectorAll('.dc-badge--bad');
		var n = 0;
		for (var i = 0; i < all.length; i++) {
			if (all[i].closest('[data-dc-triage]')) continue;
			n++;
		}
		return n;
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

	/**
	 * 切换到指定 tab。
	 *
	 * ⚠️ 必须处理滚动位置（v0.14.2 修）。
	 *
	 *   各 tab 的内容高度差别很大（「分流」约 3000px，「概览」约 900px）。
	 *   原实现只切 `hidden`，不管滚动：用户把长 tab 滚到底部再切到短 tab，
	 *   `window.scrollY` 仍停在旧值 —— 而新内容早已在视口上方，
	 *   屏幕上只剩页脚，看起来像「页面空了」。
	 *
	 *   实测：从「分流」滚到底（scrollY≈2100）切到「概览」，
	 *   概览总高约 900 + 页头，scrollY 2100 已超出可滚动范围，
	 *   浏览器把它夹到 maxScroll，但内容主体仍在视口之上。
	 *
	 *   处理方式：
	 *     · 新内容比视口高 → 滚到 tab 栏正下方（用户从头部开始读）
	 *     · 新内容比视口矮 → 滚到顶部（避免整页空白）
	 *   只在新内容顶部**已经跑到视口上方**时才动，否则会打断
	 *   用户正在短 tab 里小幅滚动的阅读位置。
	 */
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

		/* 修正滚动：新内容顶部若已在视口之上，回到 tab 栏位置 */
		try {
			var bar = document.querySelector('.dc-tabs');
			if (bar) {
				var barTop = bar.getBoundingClientRect().top + window.scrollY;
				/* 只在新内容顶部已跑到视口上方时才动 —— 否则会打断
				   用户在同高度 tab 之间切换时的小幅滚动位置 */
				if (window.scrollY > barTop + 8) {
					/* 留 8px 上边距，避免 tab 栏贴住视口顶端 */
					window.scrollTo(0, Math.max(0, barTop - 8));
				}
			}
		} catch (e) { /* 滚动失败不影响功能 */ }

		try { localStorage.setItem(STORAGE_KEY, id); } catch (e) { /* 忽略 */ }
	}

	/**
	 * 移除 CBI 自动生成的空 tab 菜单。
	 *
	 * 本页的 section 都是 TypedSection / NamedSection，CBI 会给每个 map
	 * 生成一个 <ul class="cbi-tabmenu">。我们没用 CBI 原生 tab，所以它的
	 * <li> 全是 display:none —— 但 <ul> 本身仍带主题背景色，实测渲染成
	 * 一条 6×36px 的灰色竖条，卡在描述与自建 tab 栏之间（v0.12.2 修）。
	 *
	 * CSS 里用 :has() 做了声明式处理，但老 WebKit 不支持 :has()，
	 * 这里用 JS 兜底：没有可见 <li> 的 tabmenu 直接移除。
	 */
	function dropEmptyTabmenu() {
		var menus = document.querySelectorAll('.cbi-tabmenu');
		for (var i = 0; i < menus.length; i++) {
			var ul = menus[i];
			var visible = 0;
			for (var j = 0; j < ul.children.length; j++) {
				var li = ul.children[j];
				if (getComputedStyle(li).display !== 'none') visible++;
			}
			if (visible === 0) {
				ul.parentNode && ul.parentNode.removeChild(ul);
			}
		}
	}

	/**
	 * 把「整块内容」行改成竖排（标签在上、内容占满整行）。
	 *
	 * CBI 的 .cbi-value 是「标签列 160px + 字段列」两栏布局，对短输入框
	 * 合适；但概览里 4 行放的是链路图/指标条/统计卡/表格，标签却只有
	 * 4 个汉字，左侧白空 193px —— 用户看到的「左边留白很大」就是它。
	 *
	 * CSS 里用 :has() 按内容类型匹配，这里用 JS 兜底（老 WebKit 无 :has()）。
	 * 判据：字段区第一个元素带 dc- 前缀的块级类。
	 *
	 * v0.13.0 新增两项：
	 *   · dc-inline-form —— 「单域名解释」的输入行。它自己已是 flex 容器，
	 *     放进 160px 标签列右侧会被压成极窄一列，输入框几乎不可见。
	 *   · dc-hint —— 紧跟表格的说明行，应跟着表格一起占满整行。
	 *
	 * 刻意**不含** dc-chip：chip 只在表格单元格里出现，
	 * 而 markBlockRows 只看字段区的直接子元素，加了也不会命中；
	 * 写进来反而让人以为有额外作用。
	 *
	 * v0.16.4 新增 dc-details —— 分诊结果里「已入库（审计留档）」的折叠区。
	 * 它和 dc-table-wrap 一样是整块内容，放在 160px 标签列右侧会被压窄，
	 * 表格横向溢出。
	 */
	var BLOCK_CLASSES = ['dc-chain', 'dc-metrics', 'dc-stats', 'dc-table-wrap',
		'dc-alert', 'dc-badge', 'dc-inline-form', 'dc-hint', 'dc-details'];
	function markBlockRows() {
		var fields = document.querySelectorAll('.cbi-value > .cbi-value-field');
		for (var i = 0; i < fields.length; i++) {
			var field = fields[i];
			var row = field.parentNode;
			if (!row || !row.classList) continue;
			if (row.classList.contains('dc-block-row')) continue;

			/* 只看直接子元素 —— 深层同名元素（比如表格里的 .dc-table）
			 * 不该让整行变竖排 */
			var hit = false;
			for (var j = 0; j < field.children.length; j++) {
				var el = field.children[j];
				/* ⚠️ SVG 元素（<svg>/<path>/<g>）没有 classList ——
				 *    直接 el.classList.contains() 会抛
				 *    "Cannot read properties of undefined (reading 'classList')"，
				 *    整个 init() 中断 → 后续 markBlockRows / bootAutoRefresh
				 *    全都不执行，表现为「页面看起来正常但自动刷新失效」。
				 *    实测踩过：控制台只有这一条错，却让自动刷新静默不工作。
				 */
				if (!el || !el.classList) continue;
				for (var k = 0; k < BLOCK_CLASSES.length; k++) {
					if (el.classList.contains(BLOCK_CLASSES[k])) { hit = true; break; }
				}
				if (hit) break;
			}
			if (hit) row.classList.add('dc-block-row');
		}
	}

	/**
	 * 「单域名解释」的输入行。
	 *
	 * 为什么不用 <form>：CBI 的 map 模板已经把整页包在 <form method="post">
	 * 里，再嵌 <form> 是非法 HTML —— 浏览器会丢掉内层标签，
	 * 「解释」按钮就变成了提交外层表单（= 触发保存）。
	 * 所以这里用普通 input + button，点击时自己跳转。
	 *
	 * 跳转方式：在 URL 上带 dc_explain 参数并 reload。
	 * 为什么不用 XHR：解释结果是一段结构化表格，服务端渲染最省事；
	 * 而且这是一次「看一眼就走」的查询，多一次整页加载可以接受。
	 */
	function bindExplain() {
		var box = document.querySelector('[data-dc-explain]');
		if (!box) return;

		var input = box.querySelector('[data-dc-explain-input]');
		var go = box.querySelector('[data-dc-explain-go]');
		if (!input || !go) return;

		function submit() {
			var v = (input.value || '').trim();
			if (!v) return;
			var url = new URL(window.location.href);
			url.searchParams.set('dc_explain', v);
			window.location.href = url.toString();
		}

		go.addEventListener('click', submit);
		input.addEventListener('keydown', function (ev) {
			/* Enter 提交；不拦的话 Enter 会触发外层 CBI 表单的默认提交（保存） */
			if (ev.key === 'Enter') {
				ev.preventDefault();
				submit();
			}
		});
	}

	function init() {
		meta = readMeta();
		if (!meta) return;

		dropEmptyTabmenu();
		markBlockRows();
		bindExplain();

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

	/**
	 * 实时刷新「客户机链路诊断」区块。
	 *
	 * 为什么只刷这一块而不是整页：
	 *   整页 reload 会重置 tab 位置、滚动位置、输入框里未保存的内容，
	 *   而实时链路是**持续观察**的界面 —— 每 10 秒把你弹回顶部、
	 *   把正在填的配置清掉，完全没法用。
	 *
	 * 做法：只对含「实时查询链路」的 section 发一次 GET，把返回的
	 * 同位置 DOM 替换进去。CBI 的 DummyValue 是服务端渲染的，
	 * 所以必须回服务端取，不能在前端算。
	 */
	function refreshDiag() {
		var marker = null;
		var secs = document.querySelectorAll('.cbi-section, fieldset');
		for (var i = 0; i < secs.length; i++) {
			var h = secs[i].querySelector('h3, legend');
			if (h && h.textContent.trim() === '客户机链路诊断') { marker = secs[i]; break; }
		}
		if (!marker) return;

		var xhr = new XMLHttpRequest();
		xhr.open('GET', location.pathname + location.search, true);
		xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
		xhr.onload = function () {
			if (xhr.status !== 200) return;
			try {
				var doc = new DOMParser().parseFromString(xhr.responseText, 'text/html');
				var secs2 = doc.querySelectorAll('.cbi-section, fieldset');
				var fresh = null;
				for (var j = 0; j < secs2.length; j++) {
					var h2 = secs2[j].querySelector('h3, legend');
					if (h2 && h2.textContent.trim() === '客户机链路诊断') { fresh = secs2[j]; break; }
				}
				if (!fresh || !marker.parentNode) return;
				/* 保留当前 tab 的可见性，替换内容后重新套用 */
				var wasHidden = marker.hidden;
				marker.parentNode.replaceChild(fresh, marker);
				fresh.hidden = wasHidden;
				/* 新节点没有绑过 CBI 的事件，但本区块全是只读展示 + 按钮，
				   按钮由 CBI 原生处理（form 提交），无需重绑 */
			} catch (e) { /* 解析失败保持原样，不打断用户 */ }
		};
		xhr.send();
	}

	/**
	 * 按配置启动自动刷新。
	 *
	 * 间隔从页面上的「实时刷新间隔（秒）」输入框读 —— 用户改完保存
	 * 即生效，不需要额外配置通道。0 表示不自动刷新。
	 *
	 * ⚠️ 只在「状态」tab 激活时刷：其他 tab 看不见这块，
	 *    后台刷只是白耗路由器 CPU（N2930 是低功耗 4 核）。
	 */
	function startAutoRefresh() {
		var input = null;
		var fields = document.querySelectorAll('.cbi-value');
		for (var i = 0; i < fields.length; i++) {
			var lbl = fields[i].querySelector('.cbi-value-title');
			if (lbl && lbl.textContent.indexOf('实时刷新间隔') >= 0) {
				input = fields[i].querySelector('input');
				break;
			}
		}
		var sec = input ? parseInt(input.value, 10) : 10;
		/* 便于排障：把实际读到的间隔写进 console，用户反馈「不刷新」时
		   一眼能看出是配置为 0 还是没读到 */
		if (window.console && console.info) {
			console.info('[dnschain] 自动刷新间隔 =', sec, '秒（输入框', input ? '已找到' : '未找到，用默认 10', '）');
		}
		if (isNaN(sec) || sec <= 0) return;

		setInterval(function () {
			var t = document.querySelector('.dc-tab[aria-selected="true"]');
			if (!t || t.getAttribute('data-tab') !== 'status') return;
			if (document.hidden) return;   /* 标签页在后台不刷 */
			refreshDiag();
		}, sec * 1000);
	}

	/**
	 * 等「客户机链路诊断」section 真正出现在 DOM 里再启动自动刷新。
	 *
	 * ⚠️ 为什么不能直接调 startAutoRefresh()：
	 *    LuCI 的 CBI 内容是**异步渲染**的 —— 脚本执行时
	 *    `document.readyState` 可能已是 complete，但 section 还没插进
	 *    DOM。实测：直接调用时输入框查不到、`sec` 落到默认值，
	 *    而 setInterval 里 refreshDiag 又因找不到 section 而 return，
	 *    整条链路静默失效（页面看起来正常，只是永远不刷新）。
	 *
	 *    用 MutationObserver 等到目标 section 出现再启动，是最可靠的。
	 *    最多等 30 秒，超时后放弃（不让一个观察器永久挂着）。
	 */
	function bootAutoRefresh() {
		var started = false;
		function tryStart() {
			if (started) return true;
			var secs = document.querySelectorAll('.cbi-section, fieldset');
			for (var i = 0; i < secs.length; i++) {
				var h = secs[i].querySelector('h3, legend');
				if (h && h.textContent.trim() === '客户机链路诊断') {
					started = true;
					if (window.console && console.info) {
						console.info('[dnschain] 找到诊断 section，启动自动刷新');
					}
					startAutoRefresh();
					return true;
				}
			}
			return false;
		}

		if (tryStart()) return;

		var waited = 0;
		var obs = new MutationObserver(function () {
			if (tryStart()) obs.disconnect();
		});
		obs.observe(document.body, { childList: true, subtree: true });

		/* 兜底：30 秒后停止观察（避免永久挂着） */
		var iv = setInterval(function () {
			waited += 1;
			if (started || waited > 60) {
				clearInterval(iv);
				obs.disconnect();
			}
		}, 500);
	}

	/**
	 * 安全地跑 init —— 它内部任何一步抛错都不能拖死自动刷新。
	 *
	 * ⚠️ 实测踩过：init() 里 markBlockRows 对某个元素调 classList
	 *    抛了 TypeError，整个 init 中断，紧跟其后的 bootAutoRefresh
	 *    根本不执行 → 页面看起来完全正常（tab 栏、表格都在，
	 *    因为它们在抛错之前就建好了），但自动刷新永远不启动，
	 *    用户以为「刷新功能没做」。
	 *
	 *    两层防护：
	 *      ① 把 init 包进 try/catch，出错只记日志不中断
	 *      ② bootAutoRefresh 独立调用，不依赖 init 是否成功
	 */
	function safeInit() {
		try {
			init();
		} catch (e) {
			/* 只记录，不让 UI 增强的失败影响自动刷新 */
			if (window.console && console.warn) {
				console.warn('[dnschain] init 失败（不影响自动刷新）:', e);
			}
		}
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', function () {
			safeInit();
			bootAutoRefresh();
		});
	} else {
		safeInit();
		bootAutoRefresh();
	}
})();
