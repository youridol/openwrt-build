-- Copyright (C) 2026 openwrt-build
-- 服务 → DNS 分流
-- 设计依据: docs/adr/0003-dns-chain-framework.md / 0005-remove-chinadns-ng.md
--
-- 页面定位：DNS 配置总控台。集中管理 dnsmasq / dnsproxy / SSR-Plus
-- 三层的全部可控参数，并把链路实况可视化。
--
-- 它只做配置读写、校验、下发、自检与回滚，**不实现解析逻辑** ——
-- 页面与链路解耦是「改 UI 不坏链路」的前提。
--
-- ── 视觉实现说明（v0.12.0）──────────────────────────────────────
--
-- 用户要求用 shadcn MCP 重构前端。本包是 LuCI 应用（Lua + CBI 服务端
-- 渲染），仓库里没有 React / package.json / components.json，
-- `npx shadcn@latest info` 报告 framework="Manual"、config=null。
-- shadcn 的组件都是 React 组件，在这里无法安装也无法运行。
--
-- 因此实现的是 **shadcn 的视觉语言**而非其代码：
--   - 语义色令牌（ok/warn/bad/info）定义在 dnschain.css，
--     浅色与暗色两套，跟随 <html data-darkmode>
--   - 卡片 / 徽标 / 提示条 / 指标条 / 统计卡 / 表格 六类原语
--   - Tab 用前端分组实现（单张 CBI 表单 + JS 切换），
--     服务端仍是一次渲染，点击零网络请求
--
-- ── Tab 划分（6 个）──────────────────────────────────────────────
--
--   概览  链路图 + 指标 + 组件状态        ← 首屏主角，只读
--   解析  上游 / 双栈 / 端口 / 缓存        ← dnsproxy 与 dnsmasq 缓存
--   分流  名单规模 / 导入 / 源文件 / 归属   ← gfw 名单与 nftset
--   代理  SSR-Plus 兼容 / IPv6 / 拦截      ← 与 SSR-Plus 的接口
--   DHCP  DHCP 下发 DNS                    ← dnsmasq 的 DHCP 侧
--   诊断  自检表格 + 全部操作按钮          ← 只读结果 + 动作
--
-- 每个 section 通过 s.dc_tab 归组，由 dnschain.js 收拢成 tab 面板。

local ds = require "luci.model.cbi.dnschain.dnschain"
local dg = require "luci.model.cbi.dnschain.diagrams"
-- v0.18.0：归组规则与「证据→症状」推导独立成模块（纯函数，可单测）。
-- 别名 dg2 是为了不与 dg（绘图层）混淆：dg 只管画，dg2 只管判断。
local dg2 = require "luci.model.cbi.dnschain.diagnosis"

local m, s, o

m = Map("dnschain", translate("DNS 分流"),
	translate("集中控制 DNS 解析分流。dnsmasq / dnsproxy / SSR-Plus " ..
		"三层的可控参数都在这里，按功能分 Tab。"))

------------------------------------------------------------------------
-- 让按钮的操作结果能显示到页面上
--
-- 本页 5 个按钮原先都在 write() 里写 m.message，但**从来不会显示**。
-- 实测查明的三层原因（缺一层都不显示）：
--
--   ① Button 的 write() 需要非空 formvalue 才触发
--      （cbi.lua:1424 是 `if fvalue and #fvalue > 0`）。按钮 HTML 的
--      value 是按钮文字，浏览器提交会带上。
--   ② dispatcher.lua:237 是 `local cstate = res:parse()` —— 返回值被丢弃，
--      所以 state_handler 返回什么都到不了模板。
--   ③ dispatcher.lua:298 读的是 `res.message`，即 **map 对象自身的字段**。
--
--   m.message 这个字段名是 SimpleForm 的（cbi/simpleform.htm:22），
--   Map 模板不读它 —— 这就是原写法无效的原因。
--
-- 解法：write() 登记到 _pending_message → 覆写 state_handler，
-- 在 parse 结束时写到 self.message。
------------------------------------------------------------------------

local _pending_message = nil

local function setmsg(msg)
	_pending_message = msg
end

local _orig_state_handler = m.state_handler
function m.state_handler(self, state)
	local res = _orig_state_handler and _orig_state_handler(self, state)
	if _pending_message then
		self.message = _pending_message
		_pending_message = nil
	end
	return res
end

------------------------------------------------------------------------
-- Tab 归组
--
-- 为什么用「标题文本 → tab」映射，而不是给 section 打 HTML 属性：
--
--   CBI 的 section 模板（tsection.htm / nsection.htm）只输出固定结构，
--   不读取 section 对象上的自定义字段，所以没法直接加 data-dc-tab。
--
--   可选方案是覆盖模板文件，但那会把 LuCI 的内部结构复制进本包，
--   上游升级时容易冲突。改用「按标题文本归组」：
--   服务端输出一份 { 标题 => tab } 的 JSON，前端按 <h3> 文本匹配。
--
--   代价是标题文本不能随意改（改了要同步这张表），
--   但这比复制模板稳定得多。中文标题由 translate() 处理，
--   故映射表用 translate 后的值建键。
------------------------------------------------------------------------

-- v0.19.0：6 个 tab 重划为 4 个（依据见下方 SECTION_TAB 顶部注释）。
--
-- 旧的 overview/resolve/split/proxy/dhcp 五个 id 合并为 status/upstream/lists：
--   overview          → status
--   resolve+proxy+dhcp → upstream
--   split             → lists
--   domains           → domains（不变）
--
-- ⚠️ 改这里必须同步改 dnschain.js 的 TAB_ORDER，否则 tab 不显示或顺序错乱。
local TAB_LABELS = {
	status   = translate("状态"),
	domains  = translate("域名"),
	upstream = translate("上游"),
	lists    = translate("名单"),
}

-- section 标题 → tab
--
-- ⚠️ 键必须与 m:section() 的标题**逐字一致**（translate 后）。
--   两个自定义域名 section 现在的标题不同了（国内 / 国外），
--   否则页面上会出现两个同名块，且本表也只能映射到其中一个。
--
-- ── v0.15.0：概览与诊断合并 ────────────────────────────────────
--
-- 用户要求「概览 tab 和诊断合并在一页显示，严格查重重复功能移除」。
-- 合并前两个 tab 的内容重叠严重：
--
--   概览：结论徽标 / 解析链路图 / 分流决策图 / 链路指标 / 组件状态表
--   诊断：自检 20 项表格 / 两个配置项 / 5 个操作按钮
--
-- 重复项与处置：
--
--   ① 「结论徽标」与「自检 20 项」都来自 ds.selftest()，
--      展示的是同一次采集的两种视图（一句话 vs 逐项）。
--      → 保留两者但放同一 tab：徽标在顶部给结论，表格在下给证据。
--        请求级缓存保证 selftest 只跑一次（ds.cached）。
--   ② 概览里的「分流决策」图与「域名」tab 里的判定链路图
--      是**同一个函数 dg.route_map()** 渲染两次 —— 真正的重复。
--      → 删掉概览这份，只在「域名」tab 保留（那里还有单域名解释配套）。
--   ③ 「组件状态表」与「自检第 1–7 项」信息部分重叠，但前者是
--      端口/进程的实时快照、后者是端到端判定，视角不同，都保留。
--
-- 合并后 tab 由 7 个减为 6 个，「诊断」不再是独立 tab。
--
-- ══ v0.19.0：tab 由 6 个重划为 4 个 ══════════════════════════════
--
-- ── 重划依据：DNS 分流只有三个动作，且都已自动化 ────────────────
--
--   判定（该走哪条链）→ 分诊实测 + 归属库 + 健康改道   已自动
--   落地（写成 dnsmasq 规则）→ dc_gen_dnsmasq_split    已自动
--   生效（让 dnsmasq 读到）→ apply_on_parse（保存即生效）已自动
--
--   所以页面只需提供两件事：
--     ① 告诉用户「现在什么状态」
--     ② 让用户输入「我认为该走哪条链」的域名
--   其余全是参数与诊断。
--
-- ── 4 个 tab ───────────────────────────────────────────────────
--
--   status  状态：现在通不通、分流到哪了        ← 原 overview
--   domains 域名：哪些域名我指定了走哪条        ← 原 domains
--   upstream 上游：往哪儿问、怎么问             ← 原 resolve + proxy + dhcp
--   lists   名单：规则库从哪来、多大、怎么体检   ← 原 split + 观测阈值 + 自检
--
-- 删除的两个 tab：
--   「分流」只有「名单规模」一个 section → 并入 lists
--   「代理」「DHCP」都是上游行为 → 并入 upstream
local SECTION_TAB = {
	-- ── 状态 ───────────────────────────────────────────────────
	[translate("当前状态")]      = "status",
	-- v0.22.0：改名为「DNS 分流去向」（原「DNS 分流状态」），并**登记进本表**。
	--
	-- ⚠️ 登记是必须的，漏了会让它在**每个 tab 都显示**。
	--    dnschain.js 的 activate() 对未归组 section 的处理是
	--    `if (!sec.tab) { sec.el.hidden = false; return; }` ——
	--    原意是「避免新增 section 后莫名消失」，但代价是它永远可见。
	--    实测（v0.22.0 改造后）：这张图在状态/域名/上游/名单 4 个 tab
	--    全都渲染，用户要求「仅保留状态 tab 里的这张图」。
	[translate("DNS 分流去向")]  = "status",
	-- v0.23.0：客户机链路诊断（ADR-0009）。放状态 tab —— 它是「结果」不是
	-- 「参数」（ADR-0007 判据），且是排障入口，应靠前。
	-- ⚠️ 必须登记：漏了会让它在所有 tab 都显示（见上方 v0.22.0 的教训）。
	[translate("客户机链路诊断")] = "status",
	[translate("操作")]          = "status",
	-- 自检是「状态检查」，与断点诊断同类，放状态 tab（用户确认 Q5）
	[translate("自检")]          = "status",

	-- ── 域名 ───────────────────────────────────────────────────
	[translate("自定义域名 · 国内（补全归属）")] = "domains",
	[translate("自定义域名 · 国外（补全归属）")] = "domains",
	-- v0.18.0：原先它挂在 dom_foreign 的 `s` 下（渲染在国外 section 内），
	-- 但内容是「国内+国外两个清单的合并只读视图」，语义不属国外。
	[translate("已录入清单")]     = "domains",

	-- ── 上游 ───────────────────────────────────────────────────
	[translate("国内上游")]      = "upstream",
	[translate("国外上游")]      = "upstream",
	[translate("双栈策略")]      = "upstream",
	[translate("端口与实例")]    = "upstream",
	[translate("缓存")]          = "upstream",
	[translate("SSR-Plus 兼容")] = "upstream",
	[translate("拦截与框架开关")] = "upstream",
	[translate("DHCP 下发 DNS（明文）")] = "upstream",

	-- ── 名单 ───────────────────────────────────────────────────
	[translate("名单规模")]      = "lists",
	-- v0.22.0：观测与阈值 section 已随健康探测删除，本条随之移除。
}

--- 输出 tab 元数据 + 加载静态资源
--
-- 为什么资源在 DummyValue 里输出：
--   LuCI 的 Map 页面没有「声明式附加资源」的接口（dispatcher 不提供
--   add_resource；cbi/map.htm 只渲染 section）。而 DummyValue 的
--   rawhtml 是原样输出的，浏览器会正常解析其中的 <link> 与 <script>。
--   这是最直接可靠的做法，不依赖主题内部结构。
--
-- 资源放在 htdocs/luci-static/resources/dnschain/，
-- 由 LuCI 静态路由自动暴露为 /luci-static/resources/dnschain/*。
local function emit_tab_meta(map)
	local meta = map:section(TypedSection, "dnschain", "")
	meta.anonymous = true
	meta.addremove = false
	local o = meta:option(DummyValue, "_dc_meta", "")
	o.rawhtml = true
	function o.cfgvalue()
		local function esc(s)
			-- JSON 字符串转义：反斜杠与双引号
			return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
		end
		local parts = {}
		for title, tab in pairs(SECTION_TAB) do
			parts[#parts + 1] = string.format('"%s":"%s"', esc(title), tab)
		end
		local labels = {}
		for id, lbl in pairs(TAB_LABELS) do
			labels[#labels + 1] = string.format('"%s":"%s"', id, esc(lbl))
		end

		-- ⚠️ 属性必须用**单引号**包裹。
		-- JSON 内容里有双引号，若属性用双引号（data-x="{...}"），
		-- 浏览器会在第一个 " 处截断，实测属性值只剩 "{"。
		local function attr(name, json)
			-- 内容里的单引号要转成 HTML 实体，避免提前闭合属性
			local v = (json:gsub("'", "&#39;"))
			return string.format(" %s='{%s}'", name, v)
		end

		local base = luci.config.main.resourcebase or "/luci-static/resources"

		-- ── 静态资源加版本号（v0.16.2 修）────────────────────────
		--
		-- 为什么必须加：这两个文件不带查询参数时，浏览器会按
		-- LuCI 的默认 Cache-Control 长期缓存。实测踩过：
		--
		--   改了 dnschain.js 的 countBadges()，文件已部署到
		--   /www/luci-static/…（fetch 带 nocache 能读到新内容），
		--   但页面**仍执行旧版** —— tab 徽标继续显示「10」，
		--   而用 DOM 模拟新逻辑却得出正确结果（counted=0）。
		--   换页面 URL 加 ?cachebust=1 也不生效（资源 URL 没变）。
		--
		--   这种失效最难查：服务端文件是对的、逻辑是对的、
		--   只有浏览器跑的是旧的 —— 会让人误以为代码没生效。
		--
		-- ⚠️ 版本号用 **包版本**（PKG_VERSION），不用文件 mtime。
		--   试过 nixio.fs.stat / luci.fs.stat 两条路，都会让本地校验器
		--   （tools/check-dnschain-lua.py）的桩缺失而整个文件加载失败
		--   （实测 PASS 从 132 掉到 78，报 "general.lua 能加载 FAIL"）。
		--   包版本是常量、无依赖，且语义正好 —— 「包升级了，资源该重拉」。
		local ver = "?v=1.9.0"

		return string.format(
			'<link rel="stylesheet" href="%s/dnschain/dnschain.css%s">' ..
			'<script defer src="%s/dnschain/dnschain.js%s"></script>' ..
			'<span data-dc-meta="1"%s%s></span>',
			base, ver, base, ver,
			attr("data-dc-section-tab", table.concat(parts, ",")),
			attr("data-dc-labels", table.concat(labels, ",")))
	end
end

------------------------------------------------------------------------
-- 概览：结论 + 链路图 + 指标 + 组件状态
--
-- 视觉取向：这是「诊断台」，首屏主角是**链路图** ——
-- 用户来这里的第一个问题是「现在请求怎么走、哪一段断了」。
-- 所以链路图最前，指标次之，组件状态表最后。
------------------------------------------------------------------------

s = m:section(TypedSection, "dnschain", translate("当前状态"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_conclusion", translate("结论"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local concl = result.conclusion

	-- tone 由**语义分支**直接给出，不再回读译文判色（v0.14.4 修 L1）。
	--
	-- ⚠️ 原实现用 `concl:find("未监听")` 这类中文子串判色，而 concl 是
	--    translate() 后的字符串。任何非中文界面下所有分支都不命中 →
	--    永远绿色徽标。英文界面上「国内 dnsproxy 未监听 —— 客户机全部
	--    无法解析」会显示成绿色。中文文案微调也会让判色静默失效。
	local tone
	if concl == "" then
		local entry = ds.entry_port()
		local fport = ds.foreign_port()
		local fowner = ds.port_owner(fport, "udp")
		if not ds.port_listening(entry, "udp") then
			concl = translate("国内 dnsproxy 未监听 —— 客户机全部无法解析")
			tone = "bad"
		elseif fowner == "" then
			concl = translate("国外 dnsproxy 未监听 —— gfw 域名将 SERVFAIL，国内不受影响")
			tone = "bad"
		elseif not ds.is_dnsproxy(fowner) then
			concl = translate("国外端口被其他进程占用 —— gfw 域名会走错解析器")
			tone = "bad"
		elseif not ds.port_listening("1234", "tcp") then
			concl = translate("代理未运行 —— 国外域名将失败（国内不受影响）")
			tone = "bad"
		elseif ds.ssr_ipv6() ~= "1" then
			concl = translate("IPv6 流量代理未开 —— 国外 IPv6 会直连被 RST")
			tone = "warn"
		else
			concl = translate("链路正常")
			tone = "ok"
		end
	end

	-- concl 来自自检（已翻译好的整句），tone 未知时按关键字兜底一次，
	-- 但只在拿不到语义分支时才会走到这里。
	if not tone then
		local low = concl:lower()
		if low:find("servfail") or low:find("失败") or low:find("未监听")
			or low:find("占用") or low:find("failed") or low:find("not listening") then
			tone = "bad"
		elseif low:find("未开") or low:find("warn") or low:find("disabled") then
			tone = "warn"
		else
			tone = "ok"
		end
	end

	return string.format('<span class="dc-badge dc-badge--%s">%s</span>', tone, concl)
end

-- ── 解析链路图已删除（v0.18.0，ADR-0007 §2.3）─────────────────────
--
-- 它原先是这里的一块手写内联 SVG（1120x372），画 dnsmasq→dnsproxy
-- :5353/:5336→:1234 的拓扑与端口存活色。
--
-- 删除理由：它与下面的「链路拓扑」（_live_diag_map）回答同一个问题 ——
-- 「此刻哪一段不通」。两张图并列，用户得在脑中做两次映射，
-- 与「一眼看出哪里有问题」的目标相反。
--
-- 它独有的信息（精确端口号 / PID / 组件名）已并入「组件状态」表，
-- 而那张表降级为链路拓扑的下钻（见下方 _topology）。
--
-- ⚠️ 不要因为「图看起来少了」就把它加回来：链路拓扑图的节点文案里
--    已写明每个阶段对应的组件与端口。

-- ── 链路拓扑图（v0.18.0 合并「解析链路」+「实时诊断链路」）────────────
--
-- ── 为什么合并（ADR-0007 §2.3）──────────────────────────────────
--
-- 概览原本有两块内容都在回答「链路通不通」：
--   · 解析链路（_chain_graph）   拓扑图 + 端口存活色
--   · 实时诊断链路（本项）        20 项自检按 8 个阶段重分组
--
-- 两张图并列，用户得在脑中做两次映射（「图 A 的那段」↔「图 B 的那个阶段」）。
-- 用户明确要求「用图更直观看到链路问题，直接展开看板，快速观测哪里有问题」，
-- 一张「拓扑 + 每节点状态徽标」正好是这个效果。
--
-- ── 与其余三张图的分工（这是它存在的理由，不是又一张重复图）──────
--
--   链路拓扑图（本项）        **逐段实测**。回答「哪一段真的通、哪一段是死的」。
--   分诊规则图（route_map）   域名归属规则。回答「某个域名会怎么走」。
--   分流去向（status_map）    你录入的域名各自走哪条链。回答「我配的走哪」。
--
-- v0.21.0：「改道状态」与「落点分布」两张图已随健康改道与分诊一起删除。
--
-- ── 归组与诊断交给 diagnosis.lua ────────────────────────────────
--
-- 本项只负责「取数据 + 交给绘图」，归组规则与「证据→症状」推导都在
-- diagnosis.lua（纯函数、可单测）。这样：
--   · general.lua 保持为「组装页面」
--   · 新增自检项未归组时，diagnosis.lua 会自动生成兜底阶段，不会静默丢失
--
-- ⚠️ 不新增后端调用：selftest 已被 _conclusion 调用过，请求级缓存命中。
o = s:option(DummyValue, "_live_diag_map", translate("链路拓扑"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local items = result.items or {}

	-- 归组（含兜底阶段）—— 规则在 diagnosis.lua
	local stages, fallback = dg2.group(items)

	-- 兜底阶段追加到末尾：它不属于任何链路阶段，放在最后不打断主链
	local all = {}
	for _, st in ipairs(stages) do all[#all + 1] = st end
	if fallback then all[#all + 1] = fallback end

	return dg.live_diag_map(all)
end

-- ── 断点诊断明细（图下折叠区，v0.18.0）────────────────────────────
--
-- 用户要求「联动给出出问题的地方是什么原因呈现数据」。
--
-- 图负责**定位**（哪一段红了），本项负责**解释**（为什么红、会怎样、怎么修）。
-- 放在图正下方而不是塞进图内：图的价值是扫视，塞长文本会失去这个作用。
--
-- 三种情况都覆盖（ADR-0007 §2.5）：
--   · 规则命中     → 症状 / 影响 / 排查命令
--   · 规则未命中   → 诚实说「未识别的失败模式」+ 证据原文 + 复现命令
--   · 证据为空     → 显示「证据缺失」+ 该阶段的检查项编号
--
-- 默认展开：用户明确要「直接展开看板」，不做二次点击。
o = s:option(DummyValue, "_diag_detail", translate("断点诊断"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local items = result.items or {}
	local stages, fallback = dg2.group(items)
	local fails = dg2.failures(stages, fallback)

	-- 时间戳 / 耗时 / 轮次（v0.18.0）：让用户判断这份结论有多旧
	local stamp = ""
	do
		local parts = {}
		if result.at and result.at ~= "" then
			parts[#parts + 1] = translate("运行于") .. " " .. dg.esc(result.at)
		end
		if result.dur and result.dur ~= "" then
			parts[#parts + 1] = translate("耗时") .. " " .. dg.esc(result.dur)
		end
		if result.run then
			parts[#parts + 1] = string.format(translate("第 %d 轮"), result.run)
		end
		if #parts > 0 then
			stamp = '<div class="dc-hint">' .. table.concat(parts, " · ") .. '</div>'
		end
	end

	if #fails == 0 then
		return '<div class="dc-alert dc-alert--ok">' ..
			'<span class="dc-alert__icon">✓</span><div>' ..
			translate("20 项自检全部通过，没有断点需要诊断。") ..
			'</div></div>' .. stamp
	end

	local rows = {}
	for i, f in ipairs(fails) do
		-- 状态徽标：FAIL 红、SKIP 灰
		local cls = (f.status == "SKIP") and "dc-badge--mute" or "dc-badge--bad"

		-- 「未识别」时明确标注，不假装知道
		local known = ""
		if not f.known then
			known = ' <span class="dc-badge dc-badge--mute">' ..
				translate("未识别") .. '</span>'
		end

		local ev = tostring(f.detail or "")
		if ev == "" then
			ev = translate("证据缺失")
		end

		rows[#rows + 1] = string.format(
			'<tr><td class="dc-table__num">%d</td>' ..
			'<td><span class="dc-badge %s">%s</span>%s</td>' ..
			'<td>%s</td>' ..
			'<td><b>%s</b><br/><span class="dc-hint">%s</span></td>' ..
			'<td>%s</td>' ..
			'<td><code>%s</code></td></tr>',
			i, cls, dg.esc(f.status), known,
			dg.esc(f.stage_label or "") .. " / " .. dg.esc(f.name or ""),
			dg.esc(f.symptom or ""), dg.esc(f.impact or ""),
			dg.esc(ev),
			dg.esc(f.fix or ""))
	end

	return '<div class="dc-table-wrap"><table class="dc-table">' ..
		'<thead><tr>' ..
		'<th class="dc-table__num">' .. translate("序号") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("位置") .. '</th>' ..
		'<th>' .. translate("症状与影响") .. '</th>' ..
		'<th>' .. translate("证据") .. '</th>' ..
		'<th>' .. translate("排查") .. '</th>' ..
		'</tr></thead><tbody>' ..
		table.concat(rows) ..
		'</tbody></table></div>' .. stamp
end

-- ── 组件状态与指标（折叠下钻，v0.18.0）────────────────────────────
--
-- ── 为什么折叠（ADR-0007 §2.3）──────────────────────────────────
--
-- 它原先与「解析链路」并列显示，而两者数据源几乎相同
-- （都查 port_listening / port_owner / is_dnsproxy）。
-- 一张图 + 一张表回答同一个问题，是首屏最实在的一处重复。
--
-- 现在图负责**定位**（哪一段红了），本表负责**确认**
-- （具体是哪个 PID 占了端口、缓存命中多少）。两者是定位链路上的
-- 上下游关系，不是重复。
--
-- 默认折叠：用户要「图直接展开」，但表里的精确值只有排障时才需要，
-- 全展开会把图挤下去。
o = s:option(DummyValue, "_topology", translate("组件状态与指标"))
o.rawhtml = true
function o.cfgvalue()
	local entry = ds.entry_port()
	local fport = ds.foreign_port()
	local rows = {}
	local function row(name, port, alive, note)
		rows[#rows + 1] = string.format(
			'<tr><td>%s</td><td><code>%s</code></td>' ..
			'<td><span class="dc-badge dc-badge--%s">%s</span></td>' ..
			'<td>%s</td></tr>',
			dg.esc(name), dg.esc(port),
			alive and "ok" or "bad",
			alive and translate("存活") or translate("未运行"),
			dg.esc(note))
	end

	local e_ok = ds.port_listening(entry, "udp")
	row(translate("国内 dnsproxy"), ":" .. entry, e_ok,
		e_ok and translate("监听中") or translate("未监听，客户机无法解析"))

	local f_owner = ds.port_owner(fport, "udp")
	local f_ok = (f_owner ~= "" and ds.is_dnsproxy(f_owner))
	row(translate("国外 dnsproxy"), ":" .. fport, f_ok,
		f_ok and (translate("监听中，PID ") .. f_owner)
		     or (f_owner == "" and translate("未监听，gfw 域名将 SERVFAIL")
		         or (translate("被非 dnsproxy 进程占用：") .. f_owner)))

	local p_ok = ds.port_listening("1234", "tcp")
	row(translate("代理入口"), ":1234", p_ok,
		p_ok and translate("监听中") or translate("未运行，国外域名将失败"))

	local v6_ok = (ds.ssr_ipv6() == "1")
	row(translate("IPv6 流量代理"), "ipv6_support", v6_ok,
		v6_ok and translate("已启用，国外 IPv6 也走代理") or translate("未启用"))

	local cstat = ds.cache_stats()
	local cache_ok = (cstat.dns_cache_inserted or 0) > 0
	row(translate("缓存"), "dnsmasq", cache_ok,
		string.format(translate("插入 %d / 本地应答 %d / 转发 %d"),
			cstat.dns_cache_inserted or 0,
			cstat.dns_local_answered or 0,
			cstat.dns_queries_forwarded or 0))

	return '<details class="dc-details"><summary>' ..
		translate("展开组件状态与指标") .. '</summary>' ..
		'<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("组件") .. '</th>' ..
		'<th>' .. translate("端口") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("说明") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(rows) ..
		'</tbody></table></div></details>'
end

------------------------------------------------------------------------
-- Tab「域名」：自定义列表 + 判定链路 + 改道状态（v0.13.0）
--
-- 这一页要回答三个问题，顺序就是三个 section 的顺序：
--
--   ① 我录了哪些域名？            → 自定义域名（两个输入框 + 已录入清单）
--   ② 某个域名会怎么走、为什么？  → 判定链路（思维链路图）
--   ③ 现在哪些域名不正常？        → 改道状态（状态思维导图 + 明细表）
--
-- 为什么①②③必须是同一个 tab：
--   用户改完列表后最想知道的是「这下它会怎么走」，而改道状态又直接
--   依赖归属判定。拆成两个 tab 时，用户得来回切才能把三件事对上，
--   而这三件事在逻辑上是一条链。
------------------------------------------------------------------------

-- 归属标签（两处表格共用，避免两套文案漂移）
local CLASS_LABEL = {
	["custom-domestic"] = translate("自定义 · 国内"),
	["custom-foreign"]  = translate("自定义 · 国外"),
	["db-foreign"]      = translate("数据库命中"),
	["uncovered"]       = translate("未覆盖"),
	["invalid"]         = translate("格式非法"),
}

local function ds_class_label(cls)
	return dg.esc(CLASS_LABEL[cls] or cls or "—")
end

-- 校验一个域名（页面侧第一道闸）
--
-- 与脚本里的 dc_domain_valid 保持同一套规则，但**不追求完全等价**：
-- 这里的目标是「用户敲错时立刻看到」，脚本那道闸才是权威。
-- 页面校验写得过于复杂反而会误拒合法域名（例如 xn-- 形式的 IDNA），
-- 所以这里只拦「明显不对」的形态，剩下的交给脚本。
local function validate_domain(value)
	local raw = tostring(value or "")
	local v = raw:gsub("^%s+", ""):gsub("%s+$", ""):lower():gsub("%.$", "")

	-- 空值放行：DynamicList 的「最后一行空输入」是正常的，
	-- 由 rmempty 负责把它丢掉。这里返回 nil 会被当成「校验失败」，
	-- 用户就会看到「保存成功但配置没变」这种更难查的现象。
	-- 空值返回**归一化后**的空串（v0.14.4 修 M2）。
	-- 原实现 `return value` 返回的是原始输入，若用户输入纯空格，
	-- 得到 "  " 而非 ""，rmempty 判据不认它为空 → 一个空格串被写进
	-- UCI list，随后靠 dc_domain_valid 才拦住（页面无提示）。
	if v == "" then return v end

	if v:find("%s") then
		return nil, translate("不能含空格：") .. v
	end
	if v:find("[^a-z0-9%.%-]") then
		return nil, translate("只能包含字母、数字、点与连字符：") .. v
	end
	if v:find("%.%.") or v:sub(1, 1) == "." or v:sub(-1) == "." then
		return nil, translate("点的位置不对：") .. v
	end
	if not v:find("%.") then
		return nil, translate("至少要有两级（例如 example.com）：") .. v
	end

	-- 不做「禁止 --」的检查：xn-- 是合法的 IDNA 前缀，
	-- punycode 编码结果里也会出现 --。拦它会把 IDNA 域名误拒。
	local tld = v:match("%.([^%.]+)$") or ""
	if #tld < 2 then
		return nil, translate("顶级域至少 2 位：") .. v
	end
	if tld:match("^%d+$") then
		return nil, translate("顶级域不能是纯数字：") .. v
	end

	-- ── 以下四条与 shell 的 dc_domain_valid 对齐（v0.14.4 修 M1）──
	--
	-- ⚠️ 原实现只校验前 5 条，比 dc_domain_valid 少了这 4 条。
	--    后果：页面放行、写进 UCI，随后 dc_list_normalize 里
	--    `dc_domain_valid || continue` **静默跳过** —— 该域名不生成分流
	--    规则、不参与健康检测，而「已录入清单」表格仍显示它（读的是 UCI
	--    原值）。用户看到「已录入」却完全不生效，且无任何错误。
	--
	--    判据必须保证「页面拒绝集合 ⊆ 脚本拒绝集合」，否则必然漂移。

	-- 总长 ≤ 253（DNS 协议上限）
	if #v > 253 then
		return nil, translate("总长不能超过 253 个字符：") .. v
	end

	-- 每个 label ≤ 63，且首尾不能是连字符
	local label_bad
	for label in v:gmatch("[^%.]+") do
		if #label > 63 then
			label_bad = translate("每段不能超过 63 个字符：") .. label
			break
		end
		if label:sub(1, 1) == "-" or label:sub(-1) == "-" then
			label_bad = translate("每段首尾不能是连字符：") .. label
			break
		end
	end
	if label_bad then
		return nil, label_bad
	end

	-- 顶级域：xn-- 除外，必须纯字母（shell 侧同此判据）
	if not tld:match("^xn%-%-") and tld:match("[^a-z]") then
		return nil, translate("顶级域只能是字母（IDNA 用 xn-- 前缀）：") .. v
	end

	return v
end

-- ── 自定义域名（数据库补全）──────────────────────────────────────
--
-- 定位（v0.14.0 语义矫正，务必按这个理解改代码）：
--
--   这里是**补全数据库没覆盖的域名归属**，不是「手动改道开关」。
--   写进来的域名只做一件事：告诉框架「它的归属是哪条链」。
--   之后由 dnsmasq（server=/域名/）+ dnsproxy（两个实例）按归属分流，
--   并且**仍然参与健康检测与自动改道** —— 首选链不通、另一条通时照样改道。
--
--   旧文案写的是「不参与自动改道，你写的就是最终答案」，那是错的：
--   它让用户显式补全归属的域名反而失去了自动恢复能力。
--
-- 为什么是两个 NamedSection 而不是一个 section 两个 list：
--   UCI 里它们是两个独立的 config 段（dom_domestic / dom_foreign），
--   放进同一个 NamedSection 写回时会互相覆盖。
--   但**标题必须能区分**，否则页面上会出现两个一模一样的「自定义域名」。
-- ── 多行域名输入框（v0.20.0）────────────────────────────────────
--
-- ── 为什么从 DynamicList 改成多行文本 ────────────────────────────
--
-- 用户要求：「改为一个大输入框，每一行一个域名即可」。
--
-- DynamicList 每加一个域名要点一次「+」、再填一行 —— 批量补 20 个域名
-- 就是 20 次点击。而用户手头通常已经有一份域名清单（记事本、网页、
-- 别人的配置），直接整段粘进一个大框才是自然操作。
--
-- ── 实现要点 ────────────────────────────────────────────────────
--
-- 用 TextValue（LuCI 的多行文本），但 **UCI 里仍然存成 list**。
-- 这样下游 dc_gen_custom_lists（dnschain.sh）读到的格式完全不变，
-- 后端零改动。
--
-- 关键在 write()：
--   ① 按行拆分
--   ② 逐行 trim、转小写、去掉行尾的点
--   ③ 跳过空行与 # 注释行
--   ④ 逐条用 validate_domain 校验（**逐行报错**，告诉用户是第几行）
--   ⑤ 去重后整体写回 UCI list
--
-- ── 为什么逐行校验而不是整体校验 ────────────────────────────────
--
-- 一大段文本里有一行写错时，整体校验只能说「格式不对」，
-- 用户得自己找是哪一行。逐行校验能直接说「第 7 行：点的位置不对」。
local function make_domain_textarea(s, name, label, desc, placeholder)
	local o = s:option(TextValue, name, label, desc)
	o.rows = 12
	o.wrap = "off"
	o.rmempty = true
	o.placeholder = placeholder

	-- 读：把 UCI list 拼成每行一个
	function o.cfgvalue(self, section)
		local v = self.map:get(section, self.option)
		if type(v) == "table" then
			return table.concat(v, "\n")
		end
		return v or ""
	end

	-- 写：按行拆分 → 校验 → 去重 → 写回 list
	--
	-- ── 校验策略：跳过 + 汇总提示，而不是让整页保存失败 ──────────
	--
	-- v0.20.0 第一版对每行 error()，结果实测**整页 500**：
	-- 用户既有配置里本来就含非法域名（实测 4 个 `_4483._https.*`
	-- 形式的 SRV 风格域名），于是任何一次保存都会被它们挡住，
	-- 用户无法保存任何其它改动 —— 这是比不校验更糟的回归。
	--
	-- 而且这些域名**在后端也非法**（dc_domain_valid_norm 同样拒绝
	-- 下划线），从未进入 split.conf（实测 grep 为 0），是死数据。
	--
	-- 改为：
	--   · 合法行 → 写入
	--   · 非法行 → 跳过，但记下来
	--   · 保存后把「跳过了哪几行」汇总成一条提示
	-- 这样既能清理死数据，又不阻断用户保存其它改动。
	function o.write(self, section, value)
		local raw = tostring(value or "")
		local seen, out = {}, {}
		local bad = {}

		local lineno = 0
		for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
			lineno = lineno + 1
			local t = line:gsub("^%s+", ""):gsub("%s+$", "")
			-- 跳过空行与注释行（允许用户把带注释的清单整段粘进来）
			if t ~= "" and t:sub(1, 1) ~= "#" then
				local ok, err = validate_domain(t)
				if not ok then
					bad[#bad + 1] = string.format("%d: %s", lineno, t)
				elseif ok ~= "" and not seen[ok] then
					seen[ok] = true
					out[#out + 1] = ok
				end
			end
		end

		-- ── 写回 UCI：map:set 传数组即可 ─────────────────────────────
		--
		-- 实测确认（路由器 2026-10-25）：ubus 的 uci set **支持数组**，
		-- `{"values":{"domain":["a.com","b.com"]}}` 能正确写成 list。
		-- 命令行 `uci set x.y.z="a" "b"` 报 usage 是命令行工具的局限，
		-- 不是 ubus 接口的局限 —— 这一点很容易搞混。
		--
		-- 所以这里就用 LuCI 的标准写法：map:set 传数组。
		-- 不自己调 uci:save（Map.parse 会在 Node.parse 之后统一 save），
		-- 也不自己 delete（map:set 的数组语义就是整体替换该 option）。
		self.map:set(section, self.option, out)

		-- ── 立即 commit（v0.20.0 实测必需）──────────────────────────
		--
		-- 只调 map:set 时值停在 uci 的 staging 区（/tmp/.uci/dnschain），
		-- 依赖 Map.parse 在 Node.parse 之后统一 `uci:save` 才落盘。
		-- 但实测这条链在本页面**没有生效**：
		--   · 页面回显正确（新值确实进了内存）
		--   · `uci changes dnschain` 为空
		--   · /tmp/.uci/dnschain 里也没有
		--   · /etc/config/dnschain 内容不变
		-- 也就是说值在本次请求的 Lua 进程内存里，请求结束就丢了。
		--
		-- 原因与 `apply_on_parse` 有关：本 Map 覆写了 apply_on_parse
		-- （见文件末尾），它会在 save 之后调用 ds.apply_domains()，
		-- 而那一步会重启 dnsmasq —— 整条链路的时序与默认流程不同。
		--
		-- 与其去猜 LuCI 的内部时序，不如在这里显式落盘：
		-- save（写 staging）→ commit（staging → /etc/config）。
		-- 两步都是幂等的，重复调用无副作用。
		self.map.uci:save(self.map.config)
		self.map.uci:commit(self.map.config)

		-- 有跳过项时给一条提示（用 setmsg，state_handler 会把它落到页面）
		if #bad > 0 then
			local shown = table.concat(bad, "；", 1, math.min(#bad, 3))
			if #bad > 3 then
				shown = shown .. string.format(translate("…（共 %d 条）"), #bad)
			end
			setmsg(string.format(
				translate("已跳过 %d 个格式非法的域名（后端同样不接受，不会生效）：%s"),
				#bad, shown))
		end

		-- ⚠️ 必须返回 true（v0.20.0 实测踩过）。
		--
		-- LuCI 的 AbstractValue.parse 这样调用 write：
		--     if self:write(section, fvalue) then
		--         self.section.changed = true
		--     end
		-- 不返回真值时 section.changed 不置位 → 整次保存被判定为
		-- 「没有任何改动」→ **一个字节都不会写进 UCI**，
		-- 而页面上看不出任何异常（提示消息照常显示）。
		--
		-- 这正是本版第一次部署时的现象：提示「已跳过 1 个非法域名」
		-- 正常弹出，但 `uci get dnschain.dom_foreign.domain` 毫无变化。
		return true
	end

	return o
end

s = m:section(NamedSection, "dom_domestic", "domains",
	translate("自定义域名 · 国内（补全归属）"),
	translate("手工补全数据库没覆盖的域名归属。<b>这里只决定「归属」，不是改道开关</b>：" ..
		"归属定了之后由 dnsmasq 与 dnsproxy 分流，且<b>仍然参与健康检测</b> —— " ..
		"首选链不通、另一条链通时照样自动改道。<br/>" ..
		"格式：<b>每行一个域名</b>（含 <code>xn--</code> 形式），" ..
		"空行与 <code>#</code> 开头的行会被忽略；不接受通配符、IP、URL。"))
s.addremove = false

o = make_domain_textarea(s, "domain", translate("国内域名（归属直连）"),
	translate("这些域名的归属记为国内 → 首选走国内 dnsproxy 实例（直连出口），" ..
		"解析结果同时写入 <code>china</code> IP 集。"),
	"www.baidu.com\nwww.qq.com\nwww.taobao.com")

s = m:section(NamedSection, "dom_foreign", "domains",
	translate("自定义域名 · 国外（补全归属）"),
	translate("同上，但归属记为国外 → 首选走国外 dnsproxy 实例" ..
		"（经 <code>:1234</code> 代理出口），解析结果写入 <code>blacklist</code> IP 集。" ..
		"<br/><b>每行一个域名</b>，空行与 <code>#</code> 开头的行会被忽略。"))
s.addremove = false

o = make_domain_textarea(s, "domain", translate("国外域名（归属代理）"),
	translate("这些域名的归属记为国外。同样<b>参与健康检测与自动改道</b>。"),
	"www.google.com\nwww.youtube.com\nwww.wikipedia.org")

-- ── 已录入清单（独立 section，v0.18.0 修）──────────────────────────
--
-- ⚠️ 这块原先是 `o = s:option(...)`，即沿用上面 dom_foreign 那个 `s`
--    （general.lua:870）。后果：
--
--    ① DOM 上它被渲染在「自定义域名 · 国外」section 内，
--       而它展示的是**国内 + 国外两个清单的合并只读视图** ——
--       挂在「国外」下面语义是错的。
--    ② SECTION_TAB（:134-162）里因此没有它的键，tab 归组靠的是
--       遍历 section 标题，它被当成 dom_foreign 的一部分，看不出独立性。
--
--    这是 v0.18.0 全链路审查发现的真实缺陷（ADR-0007 §1.3 ④）。
--    现在拆成独立 section：编辑国内 → 编辑国外 → 看合并清单，顺序也自然了。
s = m:section(TypedSection, "dnschain", translate("已录入清单"))
s.anonymous = true
s.addremove = false

-- 已录入清单 + 生效状态
--
-- 为什么同时显示「已保存」与「已生效」：
--   点保存只写 UCI，真正改分流要等 apply（它会重启 dnsmasq，
--   约 3 秒中断，所以不能自动触发）。只显示一份时，
--   用户保存完看不到变化会以为没生效，反复点保存。
o = s:option(DummyValue, "_domains_list", translate("清单与生效状态"))
o.rawhtml = true
function o.cfgvalue()
	local dom_uci = ds.uci_list("dom_domestic", "domain")
	local for_uci = ds.uci_list("dom_foreign", "domain")
	local dom_run = ds.custom_domestic()
	local for_run = ds.custom_foreign()

	-- 「已生效 / 待应用」徽标
	--
	-- ⚠️ 必须比「合法条数」，不能比 UCI 原始 token 数（v0.14.4 修 M4）。
	--
	--   原实现左边用 `#list`（`uci -q get` 的原始 token 数），右边用
	--   `n_run`（规范化 + 校验后的生效条数）。只要列表里有一个非法域名，
	--   两者**永久不等** —— 用户点了「重建分流规则并生效」、
	--   custom-domestic.txt 已正确重建，徽标仍显示「待应用（生效 2 条）」，
	--   反复点应用也永远等不到「已生效」。
	--
	--   现在左侧改用与 n_run 同源的「合法条数」，非法项单独用红徽标列出。
	local function count_valid(list)
		local n = 0
		for _, raw in ipairs(list) do
			if validate_domain(raw) then n = n + 1 end
		end
		return n
	end

	local function badge(list, n_run)
		local n_valid = count_valid(list)
		local n_bad = #list - n_valid
		if n_valid == n_run and n_bad == 0 then
			return '<span class="dc-badge dc-badge--ok">' .. translate("已生效") .. '</span>'
		end
		local parts = {}
		if n_valid ~= n_run then
			parts[#parts + 1] = string.format(translate("待应用（生效 %d 条）"), n_run)
		end
		if n_bad > 0 then
			parts[#parts + 1] = string.format(translate("%d 条格式非法，已跳过"), n_bad)
		end
		local tone = (n_bad > 0) and "dc-badge--bad" or "dc-badge--warn"
		return '<span class="dc-badge ' .. tone .. '">' ..
			table.concat(parts, " · ") .. '</span>'
	end

	local function chips(list, tone)
		if #list == 0 then
			return '<span class="dc-badge dc-badge--mute">' .. translate("（空）") .. '</span>'
		end
		local out = {}
		for _, d in ipairs(list) do
			out[#out + 1] = string.format(
				'<span class="dc-chip dc-chip--%s">%s</span>', tone, dg.esc(d))
		end
		return table.concat(out, " ")
	end

	local function row(title, list, n_run, tone)
		return string.format(
			'<tr><td>%s</td><td class="dc-table__num">%d</td>' ..
			'<td>%s</td><td>%s</td></tr>',
			title, #list, badge(list, n_run), chips(list, tone))
	end

	return '<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("列表") .. '</th>' ..
		'<th class="dc-table__num">' .. translate("条数") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("域名") .. '</th>' ..
		'</tr></thead><tbody>' ..
		row(translate("国内（直连）"), dom_uci, #dom_run, "dom") ..
		row(translate("国外（代理）"), for_uci, #for_run, "for") ..
		'</tbody></table></div>' ..
		'<div class="dc-hint">' ..
		translate("点「保存并应用」才会重建分流规则（会重启 dnsmasq，约 3 秒解析中断）。") ..
		'</div>'
end

-- ── 判定链路（思维链路图）──────────────────────────────────────────
-- ── 单域名解释（并入「域名」tab，v0.19.0）────────────────────────
--
-- ⚠️ 原来这里还有一个「判定链路」section，包含 dg.route_map() 规则图。
--    规则图已删除（理由见下方注释），section 头随之取消 ——
--    「单域名解释」直接挂在「已录入清单」那个 section 里。
--
--    原规则图画的「入口 → ①试直连 → ②试代理 → ③dead」与
--    「DNS 分流状态」的分流去向图语义重叠：前者讲规则、后者讲事实，
--    而用户只需要后者。规则本身在 docs/runtime/dns-chain.md 有完整记录。

-- 单域名解释：用户输入一个域名，页面把「归属 → 首选 → 探测 → 结论」摊开
--
-- 为什么用 GET 参数而不是按钮 + 会话变量：
--   这里的查询是「看一眼就走」，不该持久化成 UCI 键（那会让配置里
--   多出一个和分流无关的字段，备份/还原时也跟着跑）。
--   用一次带参数的 GET 刷新即可，服务端读 formvalue 渲染结果。
--
-- 为什么 pcall 包一层：formvalue 只在真正的 HTTP 请求上下文里可用。
--   在 CLI（lua -e）或单元测试里调本文件时它不存在，
--   直接调会抛 "attempt to call a nil value" —— 整个页面 500。
local explain_domain = ""
do
	local http = require "luci.http"
	if http and type(http.formvalue) == "function" then
		local ok, v = pcall(http.formvalue, "dc_explain")
		if ok and type(v) == "string" then
			explain_domain = v:gsub("^%s+", ""):gsub("%s+$", "")
		end
	end
end

-- ── 单域名解释（v0.19.0：原「判定链路」section 已删除）──────────────
--
-- ── 为什么删掉「判定链路」这个 section ──────────────────────────
--
-- 它原本有两块：
--   ① 「走法」规则图（dg.route_map）—— 画「入口 → ①试直连 → ②试代理
--      → ③dead」的判定规则
--   ② 「单域名解释」—— 输入域名，摊开归属/首选/两条链实测/判定
--
-- ① 被删除，理由：它与「DNS 分流状态」里的**分流去向图**语义重叠 ——
--    一张讲「规则长什么样」，一张讲「此刻实际走到哪」，而后者才是
--    用户真正需要看的。规则图是给维护者看的设计说明，不该占用户页面。
--    规则本身写在 docs/runtime/dns-chain.md 与 ADR-0006。
--
-- ② 保留（用户确认），并入「域名」tab：它是唯一能回答
--    「我输入一个域名，它会走哪条链」的工具，且不写 UCI（纯查询）。
--
-- 它挂在 dom_foreign 之后的独立 section 里，见下方「已录入清单」之后。
o = s:option(DummyValue, "_explain", translate("单域名解释"))
o.rawhtml = true
function o.cfgvalue()
	local function esc(s) return dg.esc(s) end

	-- ⚠️ 这里**不能**用 <form>。
	-- CBI 的 map 模板已经把整页包在 <form method="post"> 里，
	-- 再嵌一个 <form> 是非法 HTML：浏览器会直接丢掉内层 form 标签，
	-- 于是「解释」按钮实际提交的是**外层**表单 —— 也就是触发一次保存，
	-- 用户点「解释」却看到「配置已保存」，还会把没改完的输入一起提交。
	-- 改用普通 input + button，由 dnschain.js 绑点击后自己跳转。
	local input = string.format(
		'<div class="dc-inline-form" data-dc-explain>' ..
		'<input type="text" class="cbi-input-text" data-dc-explain-input value="%s" ' ..
		'placeholder="%s" />' ..
		'<button type="button" class="cbi-button cbi-button-action" data-dc-explain-go>%s</button>' ..
		'</div>',
		esc(explain_domain), translate("输入域名，例如 github.com"), translate("解释"))

	if explain_domain == "" then
		return input .. '<div class="dc-hint">' ..
			translate("输入一个域名，下面会列出它的归属、首选链路、两条链的实测结果与最终判定。") ..
			'</div>'
	end

	local e = ds.explain(explain_domain)

	if not next(e) then
		return input .. '<div class="dc-alert dc-alert--bad">' ..
			'<span class="dc-alert__icon">✗</span><div>' ..
			translate("取不到解释结果 —— 检查 /usr/bin/dnschain-selftest 是否存在且可执行。") ..
			'</div></div>'
	end

	local CLASS_LABEL = {
		["custom-domestic"] = translate("自定义 · 国内"),
		["custom-foreign"]  = translate("自定义 · 国外"),
		["db-foreign"]      = translate("数据库命中（gfw 名单）"),
		["uncovered"]       = translate("未覆盖（名单里没有）"),
		["invalid"]         = translate("格式非法"),
	}

	local CHAIN_LABEL = {
		domestic = translate("直连链路"),
		foreign  = translate("代理链路"),
	}

	local PROBE_TONE = {
		OK = "ok", EMPTY = "ok", NX = "info",
		TIMEOUT = "bad", FAIL = "bad",
	}

	local function probe_badge(v)
		if not v or v == "" then
			return '<span class="dc-badge dc-badge--mute">—</span>'
		end
		return string.format('<span class="dc-badge dc-badge--%s">%s</span>',
			PROBE_TONE[v] or "mute", esc(v))
	end

	local decision = e["DECISION"] or ""
	local DECISION_TONE = "ok"
	local DECISION_LABEL = decision

	if decision == "reroute-domestic" then
		DECISION_TONE = "warn"
		DECISION_LABEL = translate("改走直连")
	elseif decision == "reroute-foreign" then
		DECISION_TONE = "warn"
		DECISION_LABEL = translate("改走代理")
	elseif decision == "both-bad" then
		DECISION_TONE = "bad"
		DECISION_LABEL = translate("双链故障")
	elseif decision == "reject" then
		DECISION_TONE = "bad"
		DECISION_LABEL = translate("拒绝")
	elseif decision == "keep-domestic" then
		DECISION_LABEL = translate("保持直连")
	elseif decision == "keep-foreign" then
		DECISION_LABEL = translate("保持代理")
	end

	local function kv(k, v)
		return string.format(
			'<tr><td class="dc-kv__k">%s</td><td class="dc-kv__v">%s</td></tr>', k, v)
	end

	local rows = {
		kv(translate("域名"), '<code>' .. esc(e["DOMAIN"] or "") .. '</code>'),
		kv(translate("归属"),
			'<span class="dc-badge dc-badge--info">' ..
			esc(CLASS_LABEL[e["CLASS"]] or e["CLASS"] or "—") .. '</span>'),
		kv(translate("首选链路"),
			'<span class="dc-badge dc-badge--mute">' ..
			esc(CHAIN_LABEL[e["PREFERRED"]] or e["PREFERRED"] or "—") .. '</span>'),
		kv(translate("当前链路"),
			'<span class="dc-badge dc-badge--mute">' ..
			esc(CHAIN_LABEL[e["ACTIVE"]] or e["ACTIVE"] or "—") .. '</span>'),
		kv(translate("探测 · 直连"), probe_badge(e["PROBE_DOMESTIC"])),
		kv(translate("探测 · 代理"), probe_badge(e["PROBE_FOREIGN"])),
		kv(translate("答案 · 直连"),
			'<code>' .. esc(e["ANSWER_DOMESTIC"] ~= "" and e["ANSWER_DOMESTIC"] or "—") .. '</code>'),
		kv(translate("答案 · 代理"),
			'<code>' .. esc(e["ANSWER_FOREIGN"] ~= "" and e["ANSWER_FOREIGN"] or "—") .. '</code>'),
		kv(translate("归属来源"),
			e["CUSTOM"] == "1"
				and ('<span class="dc-badge dc-badge--info">' .. translate("自定义补全") .. '</span>')
				or ('<span class="dc-badge dc-badge--mute">' .. translate("数据库 / 未覆盖") .. '</span>')),
		kv(translate("判定"),
			string.format('<span class="dc-badge dc-badge--%s">%s</span>',
				DECISION_TONE, esc(DECISION_LABEL))),
		kv(translate("理由"), esc(e["REASON"] or "—")),
	}

	return input ..
		'<div class="dc-table-wrap"><table class="dc-table dc-kv">' ..
		'<tbody>' .. table.concat(rows) .. '</tbody></table></div>'
end

-- ══════════════════════════════════════════════════════════════
-- v0.21.0：删除「DNS 分流状态」「分诊结果」「观测与阈值」三个 section
--
-- ── 为什么删 ────────────────────────────────────────────────────
--
-- 用户要求「客户机所有流量走直连，直连不通自动改走代理」。
-- 这由 dnsproxy 的 --fallback（:5353 → :5336）在上游层完成，
-- 不需要应用层探测、判定、落库，因此三个 section 一起失去意义：
--
--   ① DNS 分流状态 —— 显示「哪些域名被改道到哪条链」。没有改道就没有它。
--   ② 分诊结果     —— 显示未知目标「直连/代理/dead」的判定与落库。
--                     未覆盖域名已由 fallback 自动兜底，无需分诊。
--   ③ 观测与阈值   —— 健康探测的开关、间隔、阈值。探测本身已删除。
--
-- ── 这三个 section 原来解决什么，现在由谁解决 ──────────────────
--
--   「未覆盖域名直连不通」      → dnsproxy --fallback 自动切代理链
--   「哪个域名该走哪条链」      → 归属判定（自定义列表 + gfw 名单）
--   「链路挂了要自动切」        → --fallback 的 upstream unavailable 触发
--
-- 净效果：页面少三个 section、少一个「清空改道状态」按钮；
-- 后端少每轮探测、少 watch.servers 双写、少分诊落库。
--
-- ⚠️ 域名 TAB 现在只剩「国内直连」与「国外代理」两个输入框 ——
--    那是用户唯一需要表达的东西：这个域名（及其所有子域名）走哪条链。
-- ══════════════════════════════════════════════════════════════

-- ── DNS 分流去向（v0.21.0 重写）────────────────────────────────────
--
-- 用户明确要求保留这张图，但语义从「健康状态」改为「静态分流去向」。
--
-- ── 数据来源 ────────────────────────────────────────────────────
--
-- 不再来自 dnschain-health 的探测状态文件（已删除），而是来自
-- **归属判定的两个产物**：
--
--   custom-domestic.txt  用户录入的国内域名（走 :5353 直连）
--   custom-foreign.txt   用户录入的国外域名（走 :5336 代理）
--
-- 这两个文件由 dc_gen_custom_lists 生成，是分流规则的直接输入。
--
-- ── 为什么不画 gfw 名单里的域名 ──────────────────────────────────
--
-- 那份名单有 **2.3 万条**，画进 SVG 既不可能也无意义。
-- 图要回答的是「**我配的**域名走哪条链」，所以只画用户自己录的。
-- 名单里那 2.3 万条的去向由「概览」tab 的链路拓扑图说明。
s = m:section(TypedSection, "dnschain", translate("DNS 分流去向"),
	translate("这里显示<b>你录入的域名</b>各自走哪条链。每个域名同时覆盖它的" ..
		"所有子域名（dnsmasq 的 <code>server=/域名/</code> 按标签后缀匹配）。" ..
		"<br/>未录入的域名默认走直连；直连不通时由 dnsproxy 自动改走代理，无需人工干预。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_status_map", translate("分流去向"))
o.rawhtml = true
function o.cfgvalue()
	local rows = {}

	-- 自定义国内 → 直连
	for _, d in ipairs(ds.custom_domestic()) do
		rows[#rows + 1] = { domain = d, chain = "domestic" }
	end
	-- 自定义国外 → 代理
	for _, d in ipairs(ds.custom_foreign()) do
		rows[#rows + 1] = { domain = d, chain = "foreign" }
	end

	return dg.status_map(rows, {})
end

-- ── 客户机链路诊断（v0.23.0，ADR-0009）────────────────────────────
--
-- 视角与「自检」不同，**不得互相替代**：
--   自检 20 项  → 路由器自身（进程 / 端口 / 规则 / 配置）
--   本 section  → 客户机实际收发（谁查了什么、收到什么、哪一段失败）
--
-- 「自检全绿但某台客户机打不开 App」正是本 section 要解释的场景。
--
-- 数据来源：dnsmasq 日志（logqueries=1）。**不抓包** —— 一期只做日志
-- 分析，覆盖四段链路的前三段；第 ④ 段（DNS 正常但 TCP 连不上）留二期。
--
-- 两层结构：
--   上层 客户机列表（IP · 主机名 / 失败数 / 最近时刻）
--   下层 某台设备的失败时间线（点开看）
--
-- ⚠️ 客户机识别用 IP + 主机名，**不用 MAC**：
--    实测三台移动设备的 MAC 都是本地管理位（随机 MAC，第 2 位为 2/6/a/e），
--    用它认设备会失效。稳定的标识是 IP（租期内固定）与主机名（设备自报）。
s = m:section(TypedSection, "dnschain", translate("客户机链路诊断"),
	translate("按<b>客户机视角</b>分析：这台设备查了什么域名、收到什么答案、" ..
		"哪一段失败。<br/>与上方「自检」互补 —— 自检看路由器自身，" ..
		"这里看客户机实际收发。「自检全绿但某台设备打不开」正是这里要解释的。"))
s.anonymous = true
s.addremove = false

-- ── 可配置项（用户明确要求「可自定义时间和条目数量」）──────────
--
-- 这些键原先只在脚本里 dc_get 读取，页面无入口 —— 用户改不了。
-- 现在暴露成输入框，保存即写 UCI（TypedSection 自动处理）。

o = s:option(Flag, "enabled", translate("启用诊断"),
	translate("关闭后不扫日志、不记录任何查询。"))
o.default = "1"
o.rmempty = false

o = s:option(Flag, "autofix_enabled", translate("启用自动自愈"),
	translate("关闭后只记录失败、给建议，不动手。手动按钮不受此限。"))
o.default = "1"
o.rmempty = false

o = s:option(Value, "interval", translate("扫描间隔（秒）"),
	translate("守护进程每这么多秒汇总一次。"))
o.datatype = "range(10,3600)"
o.default = "60"

o = s:option(Value, "fail_threshold", translate("失败阈值（次）"),
	translate("同一域名在窗口内累计失败多少次才判定「该自愈」。"))
o.datatype = "range(1,100)"
o.default = "3"

o = s:option(Value, "fail_window", translate("失败判定窗口（秒）"),
	translate("上面那个阈值的统计窗口。"))
o.datatype = "range(30,86400)"
o.default = "300"

o = s:option(Value, "flow_retain_sec", translate("查询流水保留（秒）"),
	translate("客户机完整查询链路保留多久。流水量大，默认 10 分钟。"))
o.datatype = "range(60,86400)"
o.default = "600"

o = s:option(Value, "flow_retain_max", translate("查询流水条目上限"),
	translate("超过时丢弃最旧的。"))
o.datatype = "range(50,100000)"
o.default = "1000"

o = s:option(Value, "flow_refresh", translate("实时刷新间隔（秒）"),
	translate("页面「实时查询链路」自动刷新的间隔。<b>0 = 不自动刷新</b>。" ..
		"无论是否开启，都可以用下面的「立即刷新」按钮手动刷。"))
o.datatype = "range(0,300)"
o.default = "10"

o = s:option(Value, "retain_sec", translate("失败记录保留（秒）"),
	translate("失败记录量小，默认保留 1 小时 —— 超过 1 小时看也没有用了。"))
o.datatype = "range(60,86400)"
o.default = "3600"

o = s:option(Value, "retain_max", translate("失败记录条目上限"))
o.datatype = "range(50,100000)"
o.default = "500"

o = s:option(Value, "autofix_interval", translate("自动自愈最小间隔（秒）"),
	translate("自动自愈默认每小时最多 1 次。<b>手动按钮不受此限</b> —— " ..
		"你明知可以断网才会点。"))
o.datatype = "range(60,86400)"
o.default = "3600"

o = s:option(DummyValue, "_client_nav", translate("当前视图"))
o.rawhtml = true
function o.cfgvalue()
	local sel = luci.http.formvalue("dc_host") or ""
	local kw = luci.http.formvalue("dc_q") or ""

	local p = {}

	if sel == "" then
		-- ── 第一级：在线主机列表 ──────────────────────────────────
		p[#p + 1] = '<div class="dc-metrics">' ..
			'<span class="dc-badge dc-badge--ok">' ..
			translate("第一级 · 在线主机") .. '</span>' ..
			'</div>'
		p[#p + 1] = '<div class="dc-hint">' ..
			translate("点任一主机的「查看链路」进入第二级，" ..
				"看它从哪来、到哪里去、打开主域名后跳转到哪里、到哪一步出问题。") ..
			'</div>'
	else
		-- ── 第二级：单机详情 ──────────────────────────────────────
		local host = ""
		for _, r in ipairs(ds.client_diag_hosts()) do
			if r.ip == sel then
				host = (r.host ~= "" and r.host or "")
				break
			end
		end
		p[#p + 1] = '<div class="dc-metrics">' ..
			'<span class="dc-badge dc-badge--info">' ..
			translate("第二级 · 单机链路") .. '</span> ' ..
			string.format('<span class="dc-badge dc-badge--mute">%s</span>',
				dg.esc(sel .. (host ~= "" and (" · " .. host) or ""))) ..
			'</div>'
	end

	return table.concat(p)
end

-- 搜索框（用户要求「按域名和关键词搜索」）
o = s:option(Value, "_dc_q", translate("搜索域名"),
	translate("按域名关键词过滤。留空显示全部。"))
o.rmempty = true
o.default = ""
function o.cfgvalue()
	return luci.http.formvalue("dc_q") or ""
end

o = s:option(Button, "_dc_search", translate("搜索"))
o.inputtitle = translate("搜索")
o.description = translate("按域名关键词搜索当前客户机的查询记录（不区分大小写）。")
function o.write()
	-- 只做查询参数跳转，不写配置
end

o = s:option(Button, "_flow_refresh", translate("立即刷新"))
o.inputtitle = translate("刷新")
o.description = translate("手动刷新当前视图。自动刷新间隔见上方「实时刷新间隔」。")
function o.write()
	-- 空实现：只触发页面重新渲染
end

-- ── 第一级：在线主机 ──────────────────────────────────────────
o = s:option(DummyValue, "_client_hosts", translate("在线主机"))
o.rawhtml = true
function o.cfgvalue()
	local sel = luci.http.formvalue("dc_host") or ""
	if sel ~= "" then
		-- 第二级不再显示主机表
		return ""
	end

	local rows = ds.client_diag_hosts()

	if #rows == 0 then
		return '<div class="dc-alert dc-alert--info">' ..
			'<span class="dc-alert__icon">i</span><div>' ..
			translate("没有检测到在线主机。") ..
			'</div></div>'
	end

	local trs = {}
	for _, r in ipairs(rows) do
		local host = (r.host ~= "" and r.host or "—")
		local when = tonumber(r.last_ts) or 0
		local tstr = when > 0 and os.date("%H:%M:%S", when) or "—"
		local qn = tonumber(r.queries) or 0
		local fn = tonumber(r.fails) or 0

		-- 在线状态徽标
		local onb = r.online
			and ('<span class="dc-badge dc-badge--ok">' .. translate("在线") .. '</span>')
			or ('<span class="dc-badge dc-badge--mute">' .. translate("离线") .. '</span>')

		-- 「查看链路」按钮：用 <a href> 带 dc_host 参数
		--
		-- ⚠️ 不能用 <form>（CBI 已把整页包在 form 里）。
		--    用 <a> 触发 GET 是安全的：CBI 的 save 走 POST，
		--    GET 只重新渲染页面，不写配置。
		local link = string.format(
			'<a class="dc-btn" href="?dc_host=%s">%s</a>',
			dg.esc(r.ip), translate("查看链路"))

		trs[#trs + 1] = string.format(
			'<tr>' ..
			'<td>%s</td>' ..
			'<td><code>%s</code></td>' ..
			'<td>%s</td>' ..
			'<td>%d</td>' ..
			'<td><span class="dc-badge dc-badge--%s">%d</span></td>' ..
			'<td>%s</td>' ..
			'<td><code>%s</code></td>' ..
			'<td>%s</td>' ..
			'</tr>',
			onb, dg.esc(r.ip), dg.esc(host), qn,
			fn > 0 and "warn" or "mute", fn,
			tstr, dg.esc(r.domain or "—"), link)
	end

	return '<div class="dc-table-wrap"><table class="dc-table">' ..
		'<thead><tr>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("IP") .. '</th>' ..
		'<th>' .. translate("主机名") .. '</th>' ..
		'<th>' .. translate("查询数") .. '</th>' ..
		'<th>' .. translate("失败数") .. '</th>' ..
		'<th>' .. translate("最近活动") .. '</th>' ..
		'<th>' .. translate("最近域名") .. '</th>' ..
		'<th>' .. translate("操作") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(trs) .. '</tbody></table></div>' ..
		'<div class="dc-hint">' ..
		translate("主机名来自 DHCP 租约。MAC 是随机 MAC 的设备同样能识别 —— " ..
			"这里不用 MAC 作身份。") .. '</div>'
end

-- ── 第二级：单机完整链路 ──────────────────────────────────────
o = s:option(DummyValue, "_client_flow", translate("完整链路"))
o.rawhtml = true
function o.cfgvalue()
	local sel = luci.http.formvalue("dc_host") or ""
	if sel == "" then
		return ""
	end

	local kw = luci.http.formvalue("dc_q") or ""
	local rows, title
	if kw ~= "" then
		rows = ds.client_diag_search(kw, sel, 200)
		title = string.format(
			translate("客户机 <code>%s</code> 中含「<b>%s</b>」的查询（最近 200 条）"),
			dg.esc(sel), dg.esc(kw))
	else
		rows = ds.client_diag_flow(sel, 200)
		title = string.format(
			translate("客户机 <code>%s</code> 的完整查询链路（含成功，最近 200 条）"),
			dg.esc(sel))
	end

	local head = { '<div class="dc-hint">' .. title .. '</div>' }

	if #rows == 0 then
		head[#head + 1] = '<div class="dc-alert dc-alert--info">' ..
			'<span class="dc-alert__icon">i</span><div>' ..
			(kw ~= "" and translate("没有匹配的查询记录。")
				or translate("保留期内还没有查询流水。")) ..
			'</div></div>'
		return table.concat(head)
	end

	-- 状态 → 色调与中文
	local TONE = {
		ok = "ok", nodata = "mute", nxdomain = "mute",
		refused = "warn", duplicate = "mute", pending = "mute",
		noquery = "mute", servfail = "bad", noreply = "bad",
	}
	local TEXT = {
		ok = translate("成功"), nodata = translate("无此类型"),
		nxdomain = translate("域名不存在"), refused = translate("被拒绝"),
		duplicate = translate("重复查询"), pending = translate("等待终态"),
		noquery = translate("仅查询"), servfail = translate("上游失败"),
		noreply = translate("上游无回应"),
	}

	-- 「到哪里去」：由 upstream 决定
	local ep = tostring(ds.entry_port())
	local fp = tostring(ds.foreign_port())
	local function where_to(up)
		if up == nil or up == "" then return translate("未转发"), "mute" end
		if up:find("#" .. ep) or up:find(":" .. ep) then
			return translate("直连"), "ok"
		elseif up:find("#" .. fp) or up:find(":" .. fp) then
			return translate("代理"), "warn"
		end
		return up, "mute"
	end

	local trs = {}
	for _, r in ipairs(rows) do
		local when = tonumber(r.ts) or 0
		local st = r.state or ""
		local dest, dtone = where_to(r.upstream)

		-- 域名做成「可下钻」链接：点开看该域名的完整链路
		local domlink = string.format(
			'<a href="?dc_host=%s&dc_dom=%s">%s</a>',
			dg.esc(sel), dg.esc(r.domain or ""), dg.esc(r.domain or "—"))

		trs[#trs + 1] = string.format(
			'<tr>' ..
			'<td>%s</td>' ..
			'<td><code>%s</code></td>' ..
			'<td><span class="dc-badge dc-badge--%s">%s</span></td>' ..
			'<td><span class="dc-badge dc-badge--%s">%s</span></td>' ..
			'<td><code>%s</code></td>' ..
			'</tr>',
			when > 0 and os.date("%H:%M:%S", when) or "—",
			domlink,
			TONE[st] or "mute", dg.esc(TEXT[st] or st),
			dtone, dg.esc(dest),
			dg.esc(r.answer or "—"))
	end

	head[#head + 1] = '<div class="dc-table-wrap"><table class="dc-table">' ..
		'<thead><tr>' ..
		'<th>' .. translate("时刻") .. '</th>' ..
		'<th>' .. translate("查什么（点开看链路）") .. '</th>' ..
		'<th>' .. translate("结果") .. '</th>' ..
		'<th>' .. translate("到哪里去") .. '</th>' ..
		'<th>' .. translate("答案") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(trs) .. '</tbody></table></div>'

	return table.concat(head)
end

-- ── 第二级：单域名链路详情（点域名后展开）─────────────────────
o = s:option(DummyValue, "_client_trace", translate("域名链路详情"))
o.rawhtml = true
function o.cfgvalue()
	local sel = luci.http.formvalue("dc_host") or ""
	local dom = luci.http.formvalue("dc_dom") or ""
	if sel == "" or dom == "" then
		return ""
	end

	local rows = ds.client_diag_trace(sel, dom)
	if #rows == 0 then
		return '<div class="dc-alert dc-alert--info">' ..
			'<span class="dc-alert__icon">i</span><div>' ..
			string.format(translate("保留期内没有 <code>%s</code> 的查询记录。"),
				dg.esc(dom)) ..
			'</div></div>'
	end

	-- 收集汇总字段
	local kv = {}
	for _, r in ipairs(rows) do
		if r.key == "UPSTREAM" then
			-- 格式：<上游> ×<次数>
			local one = r.value
			if r.count and r.count ~= "" then
				one = one .. " ×" .. r.count
			end
			kv.upstreams = (kv.upstreams or "") ..
				(kv.upstreams and "、" or "") .. one
		elseif r.key == "STATE" then
			local one = r.value
			if r.count and r.count ~= "" then
				one = one .. " ×" .. r.count
			end
			kv.states = (kv.states or "") ..
				(kv.states and "、" or "") .. one
		else
			kv[r.key] = r.value
		end
	end

	-- 「到哪一步出问题」：按段号推断
	--
	-- ADR-0009 §3.2 四段：
	--   ① 客户机 → dnsmasq     （有 query 无 forwarded）
	--   ② dnsmasq → dnsproxy   （有 forwarded 无 reply）
	--   ③ dnsproxy → 上游      （SERVFAIL）
	--   ④ 客户机 → 目标 IP     （需抓包，一期不覆盖）
	local verdict = translate("✅ 全链路正常，未发现失败")
	local vtone = "ok"
	if (kv.OK or "0") == "0" then
		verdict = translate("❌ 该域名全部查询失败，见下方状态分布")
		vtone = "bad"
	elseif kv.STATE and kv.STATE:find("servfail") then
		verdict = translate("⚠️ 部分查询在上游失败（第 ③ 段）")
		vtone = "warn"
	elseif kv.STATE and kv.STATE:find("noreply") then
		verdict = translate("⚠️ 部分查询转发后无回应（第 ② 段）")
		vtone = "warn"
	end

	local p = {}
	p[#p + 1] = string.format(
		'<div class="dc-metrics">' ..
		'<span class="dc-badge dc-badge--%s">%s</span>' ..
		'</div>', vtone, verdict)

	-- 链路步骤（从哪来 → 到哪去）
	local steps = {}
	steps[#steps + 1] = string.format(
		'<li><b>%s</b> <code>%s</code></li>',
		translate("从哪里来：客户机"), dg.esc(sel))
	steps[#steps + 1] = string.format(
		'<li><b>%s</b> <code>dnsmasq:53</code>（%s）</li>',
		translate("第一跳：本机 dnsmasq"), translate("唯一缓存与分流层"))
	if kv.upstreams then
		steps[#steps + 1] = string.format(
			'<li><b>%s</b> <code>%s</code></li>',
			translate("第二跳：上游实例"), dg.esc(kv.upstreams))
	end
	if kv.ANSWER then
		steps[#steps + 1] = string.format(
			'<li><b>%s</b> <code>%s</code></li>',
			translate("最终答案"), dg.esc(kv.ANSWER))
	end
	if kv.CLASS then
		steps[#steps + 1] = string.format(
			'<li><b>%s</b> <code>%s</code> → <code>%s</code></li>',
			translate("归属判定"), dg.esc(kv.CLASS),
			dg.esc(kv.PREFERRED or "—"))
	end

	p[#p + 1] = '<div class="dc-chain"><ol>' ..
		table.concat(steps) .. '</ol></div>'

	-- 统计
	local stats = {}
	if kv.COUNT then
		stats[#stats + 1] = string.format(translate("查询 %s 次"), kv.COUNT)
	end
	if kv.OK then
		stats[#stats + 1] = string.format(translate("成功 %s 次"), kv.OK)
	end
	if kv.STATE then
		stats[#stats + 1] = translate("状态分布") .. "：" .. kv.STATE
	end
	if kv.FIRST and kv.LAST then
		local f = tonumber(kv.FIRST) or 0
		local l = tonumber(kv.LAST) or 0
		if f > 0 and l > 0 then
			stats[#stats + 1] = string.format(
				translate("首次 %s · 最近 %s"),
				os.date("%H:%M:%S", f), os.date("%H:%M:%S", l))
		end
	end
	if #stats > 0 then
		p[#p + 1] = '<div class="dc-hint">' ..
			table.concat(stats, " · ") .. '</div>'
	end

	return table.concat(p)
end

-- ── 第二级：该主机的失败时间线 ────────────────────────────────
o = s:option(DummyValue, "_client_detail", translate("失败时间线"))
o.rawhtml = true
function o.cfgvalue()
	local sel = luci.http.formvalue("dc_host") or ""
	if sel == "" then
		return ""
	end

	local rows = ds.client_diag_detail(sel)
	if #rows == 0 then
		return '<div class="dc-alert dc-alert--info">' ..
			'<span class="dc-alert__icon">i</span><div>' ..
			string.format(translate("客户机 %s 在保留期内没有失败记录。"),
				dg.esc(sel)) ..
			'</div></div>'
	end

	local SEG = {
		["2"] = translate("② dnsmasq 已转发，上游无回应"),
		["3"] = translate("③ 上游明确失败"),
	}
	local ST = {
		noreply  = translate("无回应"),
		servfail = translate("上游失败"),
	}

	local trs = {}
	for _, r in ipairs(rows) do
		local when = tonumber(r.ts) or 0
		trs[#trs + 1] = string.format(
			'<tr>' ..
			'<td>%s</td>' ..
			'<td><code>%s</code></td>' ..
			'<td>%s</td>' ..
			'<td><span class="dc-badge dc-badge--bad">%s</span></td>' ..
			'<td>%s</td>' ..
			'</tr>',
			when > 0 and os.date("%H:%M:%S", when) or "—",
			dg.esc(r.domain or "—"),
			dg.esc(ST[r.state] or r.state or "—"),
			dg.esc(r.state or "—"),
			dg.esc(SEG[r.seg] or "—"))
	end

	return '<div class="dc-table-wrap"><table class="dc-table">' ..
		'<thead><tr>' ..
		'<th>' .. translate("时刻") .. '</th>' ..
		'<th>' .. translate("域名") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("原始") .. '</th>' ..
		'<th>' .. translate("失败段") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(trs) .. '</tbody></table></div>'
end

-- ── 自愈记录（两级共用）──────────────────────────────────────
o = s:option(DummyValue, "_autofix_log", translate("自愈记录"))
o.rawhtml = true
function o.cfgvalue()
	local rows = ds.client_diag_autofix_log()
	if #rows == 0 then
		return '<div class="dc-hint">' .. translate("还没有自愈记录。") .. '</div>'
	end

	local LV = { L1 = translate("清缓存"), L2 = translate("重放配置"),
	             L3 = translate("重启 dnsmasq"), L4 = translate("改归属") }
	local RES = { ok = translate("成功"), fail = translate("失败"),
	              undone = translate("已撤销") }

	local trs = {}
	for _, r in ipairs(rows) do
		local when = tonumber(r.ts) or 0
		trs[#trs + 1] = string.format(
			'<tr>' ..
			'<td>%s</td>' ..
			'<td>%s</td>' ..
			'<td><code>%s</code></td>' ..
			'<td><span class="dc-badge dc-badge--%s">%s</span></td>' ..
			'<td>%s</td>' ..
			'</tr>',
			when > 0 and os.date("%H:%M:%S", when) or "—",
			dg.esc(LV[r.level] or r.level or "—"),
			dg.esc(r.domain or "—"),
			r.result == "ok" and "ok" or (r.result == "undone" and "mute" or "bad"),
			dg.esc(RES[r.result] or r.result or "—"),
			dg.esc(r.note or ""))
	end

	return '<div class="dc-table-wrap"><table class="dc-table">' ..
		'<thead><tr>' ..
		'<th>' .. translate("时刻") .. '</th>' ..
		'<th>' .. translate("级别") .. '</th>' ..
		'<th>' .. translate("域名") .. '</th>' ..
		'<th>' .. translate("结果") .. '</th>' ..
		'<th>' .. translate("备注") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(trs) .. '</tbody></table></div>'
end

-- ── 国内上游 ──
s = m:section(NamedSection, "cn", "upstream", translate("国内上游"),
	translate("用于<b>不在</b> gfw 名单里的域名。直连出站，可混用 DoT 与 DoH，" ..
		"dnsproxy 会并行查询取最快。"))
s.addremove = false

o = s:option(DynamicList, "server", translate("上游服务器"))
o.datatype = "or(hostname, ipaddr)"
o.rmempty = false
o.validate = validate_upstream
o.placeholder = "tls://223.5.5.5"

-- ── 国外上游 ──
s = m:section(NamedSection, "foreign", "upstream", translate("国外上游"),
	translate("用于 gfw 名单里的域名。<b>必须用 DoH（https://，走 443）</b>，" ..
		"不能用 DoT（tls://，走 853）—— 实测落地节点到 853 全部 " ..
		"<code>peer sent close notify</code>，到 443 正常。"))
s.addremove = false

o = s:option(DynamicList, "server", translate("上游服务器"))
o.datatype = "or(hostname, ipaddr)"
o.rmempty = false
o.validate = validate_upstream
o.placeholder = "https://dns.google/dns-query"

-- ⚠️ 「校验上游证书」与「经代理出站」两个开关已删除（v0.19.0）。
--
--   它们都是**假开关**：可以改，但后端完全不读，改了没有任何效果。
--
--   cert_verify —— `dc_gen_foreign_args`（dnschain.sh:400-436）只写
--     --upstream / --bootstrap / --timeout / --upstream-mode / --hosts-file，
--     **没有证书相关参数**。框架始终用 dnsproxy 的默认校验行为。
--     全仓库非注释引用：配置文件 1 处 + 页面 1 处，零后端读取。
--
--   via_proxy  —— 实际出站由 SSR-Plus 的 `router_proxy` 与 `dports` 决定，
--     框架不改这两项。开关本身只是"记录一下用户的期望"。
--
--   留着一个改不动的开关，比没有更糟：用户会以为改了生效，
--   出问题时反复调它，而真正的开关在 SSR-Plus 页面。
--
--   如果将来要真正实现「证书校验开关」，需要在 dc_gen_foreign_args 里
--   接 `--insecure`（dnsproxy 的对应参数），届时再把这个开关加回来。

-- ── 双栈策略 ──
--
-- 关键联动：ipv6_support=1 时 SSR-Plus 的 get_filter_aaaa() 直接返回 0，
-- 并调 set_ipv6_dns_filter 把 dnsmasq.filter_aaaa 设为 0 —— 无论偏好填什么。
-- 页面必须如实显示「当前是否被覆盖」，不能假装滑块有效。
s = m:section(TypedSection, "aaaa", translate("双栈策略"),
	translate("国外节点通常只有 IPv4。<b>启用 IPv6 流量代理</b>时，国外 IPv6 " ..
		"也会走代理，可以保留真实 AAAA；<b>不启用</b>时，国外 IPv6 是直连，" ..
		"拿到 AAAA 会被 RST，必须抑制。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "domestic", translate("国内 AAAA"))
function o.cfgvalue()
	return translate("始终保留（国内双栈不受影响）")
end

o = s:option(DummyValue, "foreign", translate("国外 AAAA"))
o.rawhtml = true
function o.cfgvalue()
	local pref = ds.ssr_filter_aaaa()
	local eff = ds.dnsmasq_filter_aaaa()
	local v6 = ds.ssr_ipv6()
	local overridden = (v6 == "1" and pref ~= "0")

	local badge
	if eff == "0" then
		badge = '<span class="dc-badge dc-badge--ok">' .. translate("保留") .. '</span>'
	else
		badge = '<span class="dc-badge dc-badge--warn">' .. translate("抑制") .. '</span>'
	end

	if overridden then
		return badge .. ' <span style="font-size:11px;color:var(--dc-warn)">' ..
			translate("偏好值是「抑制」，但 ipv6_support=1 已强制覆盖为「保留」") ..
			'</span>'
	end
	return badge
end

-- 开关：写 shadowsocksr.@global[0].filter_aaaa
--
-- 为什么用 ListValue 而不是 Flag：
-- Flag 的 write() 拿到的 value 是 "1" 或空串，且它绑定在 aaaa.policy 这个
-- section 上；而我们要写的是**另一个包**（shadowsocksr）的键。
-- 实测用 Flag 时页面渲染成纯文本 + 说明，没有开关控件。
o = s:option(ListValue, "_filter_aaaa", translate("抑制国外 AAAA"),
	translate("写 <code>shadowsocksr.@global[0].filter_aaaa</code>。" ..
		"<br/><b>启用 IPv6 流量代理时此项无效</b> —— SSR-Plus 会强制覆盖为「保留」。" ..
		"<br/>只有<b>关闭</b> IPv6 流量代理时，此项才真正决定行为。"))
o:value("0", translate("关闭 —— 保留 AAAA（推荐）"))
o:value("1", translate("开启 —— 抑制国外 AAAA"))
o.rmempty = false
function o.cfgvalue()
	return ds.ssr_filter_aaaa() == "1" and "1" or "0"
end
function o.write(self, section, value)
	local v = (value == "1") and "1" or "0"
	-- 不能用 luci.sys.call("...%s...", v)：它不支持 %s 插值，
	-- 会把字面 "%s" 写进 UCI。
	luci.sys.call("uci -q set shadowsocksr.@global[0].filter_aaaa='" .. v ..
		"' && uci -q commit shadowsocksr")
	-- 检查结果并把错误码翻成中文（v0.14.4 修 M8）
	local ok, info = ds.sync_dnsmasq_filter_aaaa()
	if not ok and type(info) == "table" then
		if info.code == "uci_write_failed" then
			setmsg("✗ " .. translate("写入 dnsmasq.filter_aaaa 失败：") ..
				tostring(info.detail or ""))
		elseif info.code == "verify_failed" then
			setmsg("✗ " .. translate("dnsmasq 重启后 filter_aaaa 仍为 ") ..
				tostring(info.actual) .. translate("（期望 ") ..
				tostring(info.target) .. "）")
		else
			setmsg("✗ " .. translate("同步 dnsmasq.filter_aaaa 失败"))
		end
	end
end

o = s:option(DummyValue, "_aaaa_why", translate("实际生效值"))
o.rawhtml = true
function o.cfgvalue()
	local pref = ds.ssr_filter_aaaa()
	local eff = ds.dnsmasq_filter_aaaa()
	local v6 = ds.ssr_ipv6()
	return string.format(
		translate("偏好 <code>filter_aaaa=%s</code> · 生效 <code>dnsmasq.filter_aaaa=%s</code> · " ..
			"<code>ipv6_support=%s</code>"),
		pref ~= "" and pref or "?", eff ~= "" and eff or "?", v6 ~= "" and v6 or "?")
end

-- ⚠️ 「抑制 HTTPS/SVCB 记录」开关已删除（v0.19.0）。
--
--   它是**假开关**：`aaaa.policy.filter_https_rr` 全仓库非注释引用
--   只有配置文件 1 处 + 页面 1 处，**零后端读取**。
--
--   而且 v0.10.0 起这个功能本身就不需要了：IPv6 流量代理已把
--   国外 IPv6 送进代理，不再需要防 ipv6hint 泄漏。页面原文自己
--   也写着「默认关闭」+「没有运行时消费者」。
--
--   一个既不生效、又已无必要的开关，留着只会增加阅读负担。

-- ── 端口与实例 ──
s = m:section(TypedSection, "dnschain", translate("端口与实例"))
s.anonymous = true
s.addremove = false

o = s:option(Value, "entry_port", translate("国内实例端口"),
	translate("dnsproxy 实例 1 的监听端口，默认 5353。与国外端口<b>不能相同</b>。"))
o.datatype = "port"
o.placeholder = "5353"
o.rmempty = false
o.default = "5353"

o = s:option(Value, "foreign_port", translate("国外实例端口"),
	translate("dnsproxy 实例 2 的监听端口，默认 5336。框架会用 " ..
		"<code>server=/域名/127.0.0.1#本端口</code> 把 gfw 域名分流过来。"))
o.datatype = "port"
o.placeholder = "5336"
o.rmempty = false
o.default = "5336"

o = s:option(DummyValue, "_ports", translate("当前监听"))
o.rawhtml = true
function o.cfgvalue()
	local entry = ds.entry_port()
	local fport = ds.foreign_port()
	local function b(ok)
		return ok and '<span class="dc-badge dc-badge--ok">' .. translate("在监听") .. '</span>'
			or '<span class="dc-badge dc-badge--bad">' .. translate("未监听") .. '</span>'
	end
	return string.format("国内 :%s %s &nbsp; 国外 :%s %s",
		entry, b(ds.port_listening(entry, "udp")),
		fport, b(ds.port_listening(fport, "udp")))
end

-- ── 缓存 ──
s = m:section(TypedSection, "cache", translate("缓存"),
	translate("缓存只在 dnsmasq 一层。dnsproxy 不缓存 —— " ..
		"两处并存会让同一域名出现两份答案（实测：经 :53 与直连 :5353 返回不同 IP）。"))
s.anonymous = true
s.addremove = false

-- ⚠️ 「启用缓存」开关已删除（v0.19.0）。
--
--   它是个**假开关**：页面自己写着「实际始终启用 —— 框架不读这个开关」，
--   后端全仓库零读取（`cache.enabled` 只有配置文件 1 处 + 页面 1 处）。
--   留着它只会让用户以为「关掉缓存能解决问题」，而实际什么都不会变。
--
--   缓存确实始终启用，这是框架的硬约束（约束 #1「缓存只在 dnsmasq 一层」），
--   不是可选项 —— 可选项不该做成开关。

o = s:option(Value, "size", translate("条目数"),
	translate("dnsmasq 的 cache-size。当前实测 8192 条足够家用；" ..
		"过大会占内存，过小会让命中率下降。"))
o.datatype = "range(128, 65536)"
o.placeholder = "8192"
o.default = "8192"

o = s:option(DummyValue, "_cache_stat", translate("当前统计"))
o.rawhtml = true
function o.cfgvalue()
	local c = ds.cache_stats()
	local function n(k) return c[k] and tostring(c[k]) or "—" end
	return string.format(
		'<span class="dc-badge dc-badge--info">' .. translate("插入 %s") .. '</span> ' ..
		'<span class="dc-badge dc-badge--ok">' .. translate("本地应答 %s") .. '</span> ' ..
		'<span class="dc-badge dc-badge--mute">' .. translate("转发 %s") .. '</span>',
		n("dns_cache_inserted"), n("dns_local_answered"), n("dns_queries_forwarded"))
end

-- 清空缓存（v0.19.0 从「操作」搬来）
--
-- 属缓存配置，不属"操作"；且低频 —— 放在缓存 section 里语义正确。
-- 它是单条 SIGHUP：进程不重启、客户机无感知。
o = s:option(Button, "_flush_cache", translate("清空全部缓存"),
	translate("发送 SIGHUP 清空 dnsmasq 缓存：进程不重启、客户机无感知。" ..
		"「清空指定域名」做不到 —— dnsmasq 与 dnsproxy 都没有按域名淘汰单条缓存的接口。"))
o.inputstyle = "reload"
function o.write(self, section)
	local ok, msg = ds.flush_cache()
	ds.invalidate()
	setmsg((ok and "✓ " or "✗ ") .. msg)
end

------------------------------------------------------------------------
-- Tab「分流」：名单规模 + 导入 + 源文件 + nftset 归属
------------------------------------------------------------------------

s = m:section(TypedSection, "lists", translate("名单规模"),
	translate("框架从 SSR-Plus 的名单文件抽取域名，生成 " ..
		"<code>server=/域名/127.0.0.1#国外端口</code> 与对应的 nftset 规则。" ..
		"它<b>不修改</b> SSR-Plus 的源文件。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_stats", translate("规模"))
o.rawhtml = true
function o.cfgvalue()
	local st = ds.list_stats()
	local function stat(label, value, hint)
		return string.format(
			'<div class="dc-stat">' ..
			'<div class="dc-stat__label">%s</div>' ..
			'<div class="dc-stat__value">%s</div>' ..
			'<div class="dc-stat__hint">%s</div></div>',
			label, value, hint)
	end
	return '<div class="dc-stats">' .. table.concat({
		stat(translate("GFW 名单"), st.gfw_lines, translate("行（含 ipset=）")),
		stat(translate("基础名单"), st.base_lines, translate("行")),
		stat(translate("已生成分流"), st.domains, translate("条 server=/域名/")),
		stat(translate("最近更新"), st.updated ~= "" and st.updated or "—",
			translate("GFW 源文件 mtime")),
	}) .. '</div>'
end

o = s:option(DummyValue, "_ipset_audit", translate("IP 集归属核对"))
o.rawhtml = true
function o.cfgvalue()
	local sn = ds.chain_snapshot()
	local audit = ds.ipset_audit()

	local function row(name, cur, expect, note)
		local ok = (cur ~= nil)
		local badge = ok and '<span class="dc-badge dc-badge--ok">' .. translate("在册") .. '</span>'
			or '<span class="dc-badge dc-badge--bad">' .. translate("缺失") .. '</span>'
		return string.format(
			'<tr><td>%s</td><td class="dc-table__num">%s</td>' ..
			'<td class="dc-table__num">%s</td><td>%s</td><td>%s</td></tr>',
			name, cur and tostring(cur) or "—",
			expect and tostring(expect) or "—", badge, note or "")
	end

	local rows = {
		row(translate("代理 IP 集（blacklist）"), sn.blacklist, nil,
			translate("运行时动态累加，随解析的国外域名增长，不是固定值")),
		row(translate("国内 IP 段（china）"), sn.china, audit.china_src,
			translate("源 china_ssr.txt；nft 会把相邻段合并成区间，故区间数少于源行数")),
		row(translate("GFW 域名数"), audit.gfw_domains, audit.gfw_src,
			translate("源 gfw_list.conf 每域名占 2 行（server= + ipset=）")),
		row(translate("国内 IPv6 段"), audit.china6_src, audit.china6_src,
			translate("源 china6_ssr.txt，供 SSR-Plus 的 IPv6 分流使用")),
	}

	return '<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th>' .. translate("集合 / 数据库") .. '</th>' ..
		'<th class="dc-table__num">' .. translate("实测") .. '</th>' ..
		'<th class="dc-table__num">' .. translate("源行数") .. '</th>' ..
		'<th>' .. translate("状态") .. '</th>' ..
		'<th>' .. translate("说明") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(rows) .. '</tbody></table></div>'
end

-- ── 名单自动导入（v0.19.0：从「假开关」变成真开关）────────────────
--
-- ⚠️ 历史：在此之前 `lists.auto_import` 与 `import_interval` 都**没有消费者** ——
--    `dnschain-reconcile` 全仓库无任何调度器（无 cron、无 procd 实例），
--    只能由页面的「一键归一」按钮手动触发。所以「自动导入」这个开关
--    名不副实，页面自己也写着「没有定时调度」。
--
--    v0.19.0 起 reconcile 由后台守护循环调用；v0.21.0 删掉 dnschain-health
--    后，改由 init.d 的定时循环承担，这两个键仍然生效：
--      · 守护每轮探测后调一次 reconcile
--      · reconcile 内部先比名单指纹，未变则零动作（不会反复重启）
--
--    `import_interval` 仍是**描述性**的：实际节拍由
--    `health.interval`（观测与阈值）决定，因为 reconcile 搭在同一个循环里。
--    保留此键是为了兼容既有配置，且它表达的是「期望的导入频率」。
o = s:option(Flag, "auto_import", translate("自动导入"),
	translate("名单源文件变化时自动重新导入并重建分流规则。" ..
		"<br/>由守护进程每轮顺带检查（指纹未变则不做任何事，不会重启 dnsmasq）。" ..
		"<br/>关闭后需手动改配置才能让新名单生效。"))
o.rmempty = false
o.default = "1"

o = s:option(Value, "import_interval", translate("期望导入间隔（秒）"),
	translate("期望的名单检查频率。<b>实际节拍由「观测与阈值」里的" ..
		"「轮询间隔」决定</b> —— 名单检查搭在同一个守护循环里，" ..
		"不会单独起定时器。此值仅作记录。"))
o.datatype = "range(10, 3600)"
o.default = "60"
o:depends("auto_import", "1")

o = s:option(Value, "restart_threshold", translate("重启阈值（%）"),
	translate("名单行数变化超过该百分比时才重启 dnsproxy（约 1 秒解析中断）。"))
o.datatype = "range(0, 100)"
o.default = "1"

o = s:option(Value, "gfw_source", translate("GFW 名单源"),
	translate("只读源文件。框架从这里抽取域名生成分流规则，<b>不修改</b>该文件。"))
o.datatype = "file"
o.placeholder = "/etc/ssrplus/gfw_list.conf"
o.rmempty = true

o = s:option(Value, "base_source", translate("基础名单源"),
	translate("SSR-Plus 的基础域名列表，与 GFW 名单一起导入。"))
o.datatype = "file"
o.placeholder = "/etc/ssrplus/gfw_base.conf"
o.rmempty = true

o = s:option(Value, "black_source", translate("强制代理名单源"),
	translate("SSR-Plus 的 <code>black.list</code>，命中即走代理。"))
o.datatype = "file"
o.placeholder = "/etc/ssrplus/black.list"
o.rmempty = true

------------------------------------------------------------------------
-- Tab「代理」：SSR-Plus 兼容 + IPv6 + 拦截开关
------------------------------------------------------------------------

s = m:section(TypedSection, "ssr", translate("SSR-Plus 兼容"),
	translate("框架与 SSR-Plus 的接口约定。收敛器在开机、SSR 配置变更、" ..
		"定时三处重放这些不变量。"))
s.anonymous = true
s.addremove = false

o = s:option(ListValue, "mode", translate("目标 DNS 模式"),
	translate("SSR-Plus 的 <code>pdnsd_enable</code>。框架要接管解析，" ..
		"必须让它<b>不启动自己的 DNS 后端</b>，否则会有两个解析器抢答。"))
o:value("0", translate("0 — 不启 DNS 后端（推荐）"))
o:value("7", translate("7 — 模块内置 DNS"))
o.rmempty = false
o.default = "0"

o = s:option(Flag, "enforce", translate("强制写回"),
	translate("关闭后只告警、不修改 SSR-Plus 的键。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "require_ipv6", translate("要求启用 IPv6 流量代理"),
	translate("国外节点只有 IPv4。开启后收敛器会强制 <code>ipv6_support=1</code>，" ..
		"SSR-Plus 会装上 IPv6 代理链（<code>ss_spec6_*</code> + 策略路由），" ..
		"国外 IPv6 也走代理，从而可以保留国外 AAAA。" ..
		"<br/><b>不要关闭</b>：关闭后国外域名拿到真实 AAAA 却直连，会被 RST。"))
o.rmempty = false
o.default = "1"

o = s:option(DummyValue, "_ssr_state", translate("SSR-Plus 当前状态"))
o.rawhtml = true
function o.cfgvalue()
	local mode = ds.ssr_mode()
	local v6 = ds.ssr_ipv6()
	local gs = (luci.sys.exec("uci -q get shadowsocksr.@global[0].global_server 2>/dev/null") or ""):gsub("%s+", "")
	local rp = (luci.sys.exec("uci -q get shadowsocksr.@access_control[0].router_proxy 2>/dev/null") or ""):gsub("%s+", "")
	local es = (luci.sys.exec("uci -q get shadowsocksr.@global[0].enable_switch 2>/dev/null") or ""):gsub("%s+", "")

	local function b(ok, txt)
		return string.format('<span class="dc-badge dc-badge--%s">%s</span>',
			ok and "ok" or "warn", txt)
	end

	local parts = {
		"pdnsd_enable=" .. (mode ~= "" and mode or "?") ..
			" " .. b(mode == "0", mode == "0" and translate("已让位") or translate("会冲突")),
		"ipv6_support=" .. (v6 ~= "" and v6 or "?") ..
			" " .. b(v6 == "1", v6 == "1" and translate("已启用") or translate("未启用")),
		"router_proxy=" .. (rp ~= "" and rp or "?") ..
			" " .. b(rp == "1", rp == "1" and translate("出向走代理") or translate("直连")),
		"enable_switch=" .. (es ~= "" and es or "?") ..
			" " .. b(es == "0", es == "0" and translate("已关（推荐）") or translate("会周期性重启")),
	}
	if gs == "nil" then
		parts[#parts + 1] = '<span class="dc-badge dc-badge--bad">' ..
			translate("global_server=nil —— 客户机 DNS 会全部超时") .. '</span>'
	else
		parts[#parts + 1] = "global_server=" .. (gs ~= "" and gs or "?") ..
			" " .. b(gs ~= "" and gs ~= "nil", translate("正常"))
	end

	return table.concat(parts, '<br/>')
end

-- ── 拦截总开关 ──
s = m:section(TypedSection, "dnschain", translate("拦截与框架开关"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用 DNS 分流框架"),
	translate("关闭后框架不生成分流规则、不启动自己的 dnsproxy 实例。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "intercept", translate("强制拦截客户机 DNS"),
	translate("开启：拦截静态 IP 客户机与 DHCP 客户机的 53，DHCP 下发路由器自身地址。" ..
		"关闭：只过滤不监听，客户机自行解析（DHCP 下发 DNS 生效）。"))
o.rmempty = false
o.default = "1"

o = s:option(Flag, "intercept_dot", translate("拒绝 LAN 出向 853（DoT/DoQ）"),
	translate("让自带 DoT 的客户端快速失败并回落明文 53，从而被本框架的策略覆盖。" ..
		"<br/>规则优先级 <code>-151</code>，先于 SSR-Plus 的 <code>mangle(-150)</code>。" ..
		"<br/><b>与「对客户机提供 DoH/DoT 服务端」互斥。</b>"))
o.rmempty = false
o.default = "1"

-- ⚠️ 「尽力阻断公共 DoH」开关已删除（v0.19.0）。
--
--   页面原文自己写着「443 无法可靠区分 DoH 与普通 HTTPS，
--   故此项只做**标注**，不实际拦截」—— 也就是承认它没有任何作用。
--   后端同样零读取（`dnschain.main.intercept_doh` 只有配置 1 处 + 页面 1 处）。
--
--   保留一个明确写着"不实际拦截"的开关，只会让用户以为点开就能防住
--   DoH 绕过，实际不能。真正的防护是 `intercept_dot`（拒绝 853）——
--   那个是真的生效的，已保留。

------------------------------------------------------------------------
-- Tab「DHCP」：DHCP 下发 DNS
------------------------------------------------------------------------

s = m:section(TypedSection, "dhcp_dns", translate("DHCP 下发 DNS（明文）"),
	translate("仅在「强制拦截客户机 DNS」关闭时下发给 DHCP 客户机。" ..
		"拦截开启时，DHCP 一律下发路由器自身地址。最多 4 个。"))
s.anonymous = true
s.addremove = false

o = s:option(Flag, "enabled", translate("启用自定义下发"))
o.rmempty = false
o.default = "1"

o = s:option(DynamicList, "server", translate("DNS 地址"))
o.datatype = "ip4addr"
o.rmempty = true

o = s:option(DummyValue, "_dhcp_state", translate("实际下发"))
o.rawhtml = true
function o.cfgvalue()
	local intercept = (luci.sys.exec("uci -q get dnschain.main.intercept 2>/dev/null") or ""):gsub("%s+", "")
	local lan = (luci.sys.exec("uci -q get network.lan.ipaddr 2>/dev/null") or ""):gsub("%s+", "")
	if intercept == "1" then
		return string.format('<span class="dc-badge dc-badge--info">%s</span>',
			translate("拦截已开启 → 下发路由器自身 ") .. (lan ~= "" and lan or "192.168.3.254"))
	end
	return string.format('<span class="dc-badge dc-badge--mute">%s</span>',
		translate("拦截已关闭 → 下发上方列表"))
end

------------------------------------------------------------------------
-- 概览与诊断（合并 tab，v0.15.0）
--
-- 原「诊断」是独立 tab，内容为：自检 20 项表格 + 两个配置项 + 5 个按钮。
-- 合并后归入 overview，与「当前状态」（结论 / 解析链路 / 实时诊断链路 /
-- 链路指标 / 组件状态）连成一条「先看结论 → 再看逐段证据 → 最后动手」
-- 的阅读顺序。
--
-- 重复项已在合并时消除：概览原有的「分流决策」图是「域名」tab 判定链路
-- 图的第二次渲染（同一函数 dg.route_map），已删除；改用本页独有的
-- 「实时诊断链路」图，它按链路阶段重新组织 selftest 的 20 项结果。
------------------------------------------------------------------------

s = m:section(TypedSection, "selftest", translate("自检"),
	translate("20 项检查覆盖链路可达性、分流正确性、上游加密、双栈策略、" ..
		"fw4 可加载性与明文旁路。<br/>" ..
		"页面加载时自动跑一次（复用 10 秒内结果）；需要强制重跑点「操作」里的按钮。"))
s.anonymous = true
s.addremove = false

o = s:option(DummyValue, "_selftest", translate("结果"))
o.rawhtml = true
function o.cfgvalue()
	local result = ds.selftest()
	local rows = {}

	for _, it in ipairs(result.items or {}) do
		local cls = (it.status == "PASS") and "dc-badge--ok"
			or (it.status == "SKIP") and "dc-badge--mute" or "dc-badge--bad"
		rows[#rows + 1] = string.format(
			'<tr><td class="dc-table__num">%d</td>' ..
			'<td><span class="dc-badge %s">%s</span></td>' ..
			'<td>%s</td><td>%s</td></tr>',
			-- name/detail 来自脚本 stdout，必须转义（v0.14.4 修 L2）：
			-- 证据串里可能出现 & 或 <（如 ss_spec&blacklist），
			-- 不转义会被当实体起始、或吞掉后续文本。
			it.no or 0, cls, it.status, dg.esc(it.name or ""), dg.esc(it.detail or ""))
	end

	local fail_n = (result.total or 0) - (result.pass or 0) - (result.skip or 0)
	local skip_n = result.skip or 0

	-- 徽标颜色按**数值**决定，不能固定用红色。
	-- 否则 FAIL 0 也会渲染成 dc-badge--bad，前端统计「异常数」时
	-- 会把它算成 1 项失败（实测：诊断 tab 显示红色 1，而实际 FAIL=0）。
	local function tone(n, bad_cls)
		if n > 0 then return bad_cls end
		return "dc-badge--mute"
	end

	local summary = string.format(
		'<span class="dc-badge dc-badge--ok">PASS %d</span> ' ..
		'<span class="dc-badge %s">FAIL %d</span> ' ..
		'<span class="dc-badge dc-badge--mute">SKIP %d</span>',
		result.pass or 0, tone(fail_n, "dc-badge--bad"), fail_n, skip_n)

	return '<div style="margin-bottom:10px">' .. summary ..
		(result.conclusion ~= "" and (' &nbsp; <span class="dc-badge dc-badge--info">' ..
			result.conclusion .. '</span>') or "") .. '</div>' ..
		'<div class="dc-table-wrap"><table class="dc-table"><thead><tr>' ..
		'<th class="dc-table__num">#</th><th>' .. translate("结果") .. '</th>' ..
		'<th>' .. translate("检查项") .. '</th><th>' .. translate("证据") .. '</th>' ..
		'</tr></thead><tbody>' .. table.concat(rows) .. '</tbody></table></div>'
end

-- ⚠️ 「失败自动回滚」与「定时自检间隔」两个开关已删除（v0.19.0）。
--
--   两者都是**假开关**：
--
--   auto_rollback  —— 页面原文写着「回滚逻辑尚未实现（失败时只记日志，
--     不会自动回滚配置）」。全仓库零消费者。用户点开它会以为配置
--     坏了能自动恢复，实际不会 —— 这是最危险的一类假开关。
--
--   selftest.interval —— 页面原文写着「仓库里没有定时调度（无 cron、
--     无 procd 实例）」。全仓库零消费者。
--
--   两者都涉及**未实现的功能**。删除开关不等于放弃功能：
--   将来真要做自动回滚/定时自检时，应该先实现后端再补开关，
--   而不是先放一个不生效的开关让用户误以为已经有了。
--
--   ⚠️ 注意与 `lists.auto_import` 的区别：那个开关在本版**真的接上了**
--   消费者（后台守护每轮调 reconcile），所以保留。
--   判据是「后端有没有真的读它」，不是「名字听起来像自动」。

-- ── 操作 ──
--
-- 全部写操作后必须 ds.invalidate()：v0.11.1 加了请求级缓存，
-- selftest / chain_snapshot / list_stats 在同一请求内只跑一次。
-- 按钮执行完若不清缓存，页面显示的还是旧结果 —— 用户会以为「点了没反应」。
-- ── 操作（v0.19.0：8 个按钮 → 1 个）────────────────────────────────
--
-- ── 为什么只剩「立即重新自检」一个按钮 ──────────────────────────
--
-- 其余 7 个按钮要么与别处重复，要么已被自动化取代：
--
--   ① 重建分流规则并生效 → 删。与页底「保存并应用」调同一个
--      `ds.apply_domains()`（见上方「域名操作」的删除说明）。
--
--   ② 一键归一 → 删。v0.19.0 起 `dnschain-reconcile` 由 health 守护
--      每轮自动调用（后台守护循环），用户不需要再点。
--      它做的两件事（归一不变量 + 导入名单）都变成后台自动。
--
--   ③ 立即分诊未知目标 → 删（分诊功能本身已在 v0.21.0 移除）
--      `dc_triage_cycle`（dnschain.sh:2186），随健康守护按
--      `health.interval` 自动跑。按钮只是提前触发同一件事。
--
--   ④ 更新 GFW 名单 → 删。由 SSR-Plus 自己的定时任务更新，
--      框架侧的 `lists.auto_import` 会在下一轮收敛时自动导入。
--      保留按钮等于让用户手动做一件本来就会自动发生的事。
--
--   ⑤ 立即探测一轮 → 删。health 守护已按 `health.interval` 自动跑；
--      需要提前触发时改一次 `观测与阈值` 的间隔即可。
--
--   ⑥ 清空全部缓存 → 移到「上游」tab 的缓存 section。它属缓存配置，
--      不属"操作"；且低频。
--
--   ⑦ 清空改道状态 → 移到「DNS 分流状态」的折叠区。它是排障动作，
--      排障时就地可用才有意义。
--
-- 保留的唯一理由：「立即重新自检」是**唯一需要用户主动触发的**动作 ——
-- 页面默认复用 10 秒内的缓存结果，只有它能让用户强制真跑一次。
--
-- 全部写操作后必须 ds.invalidate()：v0.11.1 加了请求级缓存，
-- selftest / chain_snapshot / list_stats 在同一请求内只跑一次。
-- 按钮执行完若不清缓存，页面显示的还是旧结果 —— 用户会以为「点了没反应」。
s = m:section(TypedSection, "dnschain", translate("操作"))
s.anonymous = true
s.addremove = false

o = s:option(Button, "_selftest_now", translate("立即重新自检"),
	translate("重新执行全部 20 项自检。页面默认复用 10 秒内的结果以加快加载，" ..
		"点此可强制真跑一次（绕过缓存）。"))
o.inputstyle = "apply"
function o.write(self, section)
	ds.invalidate("selftest")
	-- ⚠️ 必须传 true（v0.16.5）：selftest 有 10 秒跨请求 TTL 缓存，
	--    不传 force 的话用户点完按钮可能读到缓存里的旧结果，
	--    看起来像「按钮没生效」。这是引入缓存后必须同步的一处。
	local r = ds.selftest(true)
	setmsg(translate("已重新自检") .. "：" ..
		string.format("PASS=%d", r.pass or 0) ..
		(r.conclusion ~= "" and (" — " .. r.conclusion) or ""))
end


-- ⚠️ 以下按钮已全部删除，去向见本 section 顶部注释：
--    _apply_domains  → 与「保存并应用」重复（整节删除）
--    _reconcile      → 改由收敛器每轮自动调用
--    _update_gfw     → 由 SSR-Plus 自身定时任务 + auto_import 接管
--    _flush_cache    → 移到「上游」tab 的缓存 section
--
-- v0.21.0 又删掉两个（健康改道与分诊整体移除）：
--    _triage         → 分诊功能删除，未覆盖域名由 --fallback 自动兜底
--    _cycle_now      → 健康探测删除
--    _reset_health   → 改道状态删除，无需清空

------------------------------------------------------------------------
-- Tab 元数据（必须在最后建，渲染时输出给前端归组用）
------------------------------------------------------------------------

emit_tab_meta(m)

------------------------------------------------------------------------
-- 底部「保存并应用」与「保存」的语义区分
--
-- CBI 的 Map 模板会在页面底部自动生成两个按钮：
--   保存        → 只写 UCI（cbi-map.htm 的 save 动作）
--   保存并应用  → 写 UCI 后调用本 Map 的 apply_on_parse（若已定义）
--
-- 本页原来**没有**定义 apply_on_parse，于是「保存并应用」实际等于
-- 「保存」—— 两个按钮做同一件事，用户点「保存并应用」后以为分流
-- 已经生效，但静态片段并没有重建，页面上「待应用」的徽标还在。
-- 这是 v0.14.0 全链路审查发现的真实缺陷。
--
-- 现在补上：apply_on_parse 调 ds.apply_domains()（重建分流片段 +
-- 必要时重启 dnsmasq），让「保存并应用」真的「应用」。
--
-- 注意 apply_domains 内部已经做了「静态片段未变则不动 dnsmasq」的
-- 判断（MD5 比对），所以只改阈值之类的无关字段时不会白白断 3 秒。
function m.apply_on_parse(...)
	-- 先让 CBI 完成默认的解析与写盘，再执行应用动作。
	-- 顺序不能反：apply_domains 读的是已落盘的 UCI 值。
	local rv
	if Map.apply_on_parse then
		rv = Map.apply_on_parse(...)
	end
	local ok, out = pcall(ds.apply_domains)
	ds.invalidate()
	m.message = apply_message(ok, out)
	return rv
end

-- 把 apply 的输出翻成一句给用户看的话。
--
-- v0.21.0：输出契约变更。原来解析 `dnschain-health apply` 的
-- `DNSMASQ=restarted|sighup|unchanged|skipped` 五种状态；
-- 该脚本删除后，apply 移到 `dnschain-selftest apply`，输出改为：
--
--   成功：OK=国内 N 条、国外 M 条，分流 K 条已生效
--   失败：ERROR=<原因>
--
-- 所以这里只需判 OK= / ERROR= 两种。比原来简单，但**必须仍然覆盖
-- 失败出口** —— v0.14.4 修过的 S6 缺陷是「ERROR 时显示 ✓ 已应用」，
-- 符号与结论矛盾，用户会以为成功。
function apply_message(ok, out)
	if not ok then
		return "✗ " .. translate("应用失败：") .. tostring(out)
	end
	out = out or ""

	-- 失败出口优先：出现 ERROR= 就是失败，不管有没有 OK=
	local err = out:match("ERROR=([^\n]+)")
	if err then
		return "✗ " .. translate("应用失败：") .. err
	end

	local okmsg = out:match("OK=([^\n]+)")
	if not okmsg then
		return "✗ " .. translate("应用结果不明（脚本无输出）")
	end

	return "✓ " .. translate("已应用") .. "：" .. okmsg
end

return m
