-- ============================================================
-- diagrams-chain.lua — DNS 分流全链路思维导图（v0.24.0）
--
-- 与 diagrams.lua 的分工：
--   diagrams.lua  运行时状态图（route_map / status_map / live_diag_map）
--                  —— 回答「现在通不通」
--   本文件        静态架构图（链路 + 数据流向 + 查询时序）
--                  —— 回答「它到底怎么工作的」
--
-- 数据依据：2026-10-25 在 OpenWrt 24.10.5 上的实测快照，
-- 每个节点的数字都来自实际命令输出，不是设计文档的推断。
--
-- 遵守 diagrams.lua 的两条既有约定：
--   ① 颜色一律走 CSS 变量，跟随明暗主题，不写死色值
--   ② 不画箭头（v0.15.0 起移除）—— 靠曲线形状与颜色表达走向，
--      箭头在密集分支处互相压盖反而看不清
-- ============================================================

local dg = require "luci.model.cbi.dnschain.diagrams"

local M = {}

local esc = dg.esc

-- ------------------------------------------------------------
-- 配色
--
-- ⚠️ diagrams.lua 的 `C` 只有 5 个语义色（ok/warn/bad/info/mute），
--    没有 text / bg / border / line / accent。
--    本文件需要更细的层次，故在它之上补一层；仍然全部走 CSS 变量。
--    实际存在的令牌见 dnschain.css：
--      --dc-ok / --dc-warn / --dc-bad / --dc-info / --dc-idle
--      --dc-border / --dc-fg
--    没有 --dc-bg / --dc-bg-soft，故背景一律用 fill="none"（透明），
--    靠描边区分层次 —— 这样在明暗两种主题下都不会出现「白底白字」。
-- ------------------------------------------------------------
local C = {
	ok     = dg.colors.ok,
	warn   = dg.colors.warn,
	bad    = dg.colors.bad,
	accent = dg.colors.info,
	-- 次要文字：不用 --dc-idle。
	--
	-- 实测（浏览器 computed style，深色主题）：
	--   --dc-idle = rgb(100,116,139)，在 #1e1e1e 背景上对比度仅 2.4:1，
	--   而正文要求 4.5:1 —— 图里那一片「看不清的小字」就是它。
	--
	-- 改用「主色 + 降低不透明度」：对比度随主题自动成立，
	-- 亮色下是深灰、暗色下是浅灰，无需为两套主题各写一份色值。
	--
	-- ⚠️ 不能与 C.text 用同一个值 —— 两者都是 currentColor 时
	--    `f == C.muted` 恒真，会把标题也压到 0.72 透明度。
	--    实测踩过：三张图的标题全部变灰。
	--    故 muted 用一个**带标记的独立字符串**，在 txt() 里识别后替换。
	muted  = "@muted@",
	-- 主文字：直接用 currentColor 关键字。
	-- CSS 里 --dc-fg 的值就是 currentColor，多套一层 var() 在部分
	-- WebView 里会解析失败、退化成黑色 —— 深色主题下就看不见了。
	text   = "currentColor",
	-- --dc-border 是真实存在的令牌（见 dnschain.css），
	-- 但 dg.colors 里没有导出它，故此处直接写变量名。
	border = "var(--dc-border)",
}

local function svg_open(w, h, fig)
	return string.format(
		'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" ' ..
		'width="100%%" style="max-width:%dpx" class="dc-svg" data-dc-figure="%s">',
		w, h, w, esc(fig or ""))
end

local function rect(x, y, w, h, stroke, rx)
	return string.format(
		'<rect x="%d" y="%d" width="%d" height="%d" rx="%d" fill="none" ' ..
		'stroke="%s" stroke-width="1.5"/>',
		math.floor(x), math.floor(y), math.floor(w), math.floor(h), rx or 6, stroke or C.border)
end

local function txt(x, y, s, size, fill, anchor, weight)
	-- 次要文字（C.muted）靠 opacity 压暗，而不是换一个更暗的色值。
	-- 这样亮色/暗色主题下对比度都成立 —— 换色值只在其中一套里合适。
	local f = fill or C.text
	local op = ""
	if f == C.muted then
		f = "currentColor"
		op = ' opacity="0.72"'
	end
	return string.format(
		'<text x="%d" y="%d" font-size="%d" fill="%s" text-anchor="%s"%s%s>%s</text>',
		math.floor(x), math.floor(y), math.floor(size or 12), f, anchor or "start",
		weight and (' font-weight="' .. weight .. '"') or "", op, esc(s))
end

local function line(x1, y1, x2, y2, color, width, dash)
	-- ⚠️ stroke-width 用 %s 而非 %d：调用方会传 1.5，
	--    而 Lua 5.5 的 string.format("%d", 1.5) 直接抛
	--    「number has no integer representation」。
	return string.format(
		'<line x1="%d" y1="%d" x2="%d" y2="%d" stroke="%s" stroke-width="%s"%s/>',
		math.floor(x1), math.floor(y1), math.floor(x2), math.floor(y2),
		color or C.border, tostring(width or 1.5),
		dash and (' stroke-dasharray="' .. dash .. '"') or "")
end

-- 竖向连线：直线（不用箭头，靠下方节点的位置表达走向）
local function down(x, y1, y2, color)
	return line(x, y1, x, y2, color or C.border, 1.5)
end

-- 横向连接曲线（贝塞尔控制点在两点之间，不越界）
local function curve(x1, y1, x2, y2, color)
	local mx = math.floor((x1 + x2) / 2)
	return string.format(
		'<path d="M %d %d C %d %d, %d %d, %d %d" stroke="%s" ' ..
		'stroke-width="1.5" fill="none" stroke-linecap="round"/>',
		x1, y1, mx, y1, mx, y2, x2, y2, color or C.border)
end

-- ------------------------------------------------------------
-- 图 1：全链路拓扑（客户端 → 出网）
-- ------------------------------------------------------------
function M.topology()
	local W, H = 960, 910
	local p = { svg_open(W, H, "chain-topology") }

	p[#p + 1] = txt(W / 2, 28, "DNS 分流全链路", 18, C.text, "middle", "600")
	p[#p + 1] = txt(W / 2, 50,
		"客户机发起 → dnsmasq 分流 → dnsproxy 加密上游 → 出网（直连 / 代理）",
		12, C.muted, "middle")

	local y = 76
	local x0 = 30
	local fw = W - 60

	-- ── ① 客户机 ─────────────────────────────────────────────
	p[#p + 1] = rect(x0, y, fw, 78, C.border)
	p[#p + 1] = txt(48, y + 24, "① 客户机", 13, C.text, "start", "600")
	p[#p + 1] = txt(48, y + 46,
		"DHCP 下发：网关 192.168.3.254 · DNS 192.168.3.254 · MTU 1500", 11, C.muted)
	p[#p + 1] = txt(48, y + 66,
		"发起 UDP/TCP 53 查询（明文；会被 fw4 的 dns_intercept_lan 劫持到本机）",
		11, C.muted)
	y = y + 78

	p[#p + 1] = down(W / 2, y, y + 26, C.accent)
	y = y + 26

	-- ── ② dnsmasq ────────────────────────────────────────────
	local dh = 202
	p[#p + 1] = rect(x0, y, fw, dh, C.accent)
	p[#p + 1] = txt(48, y + 24, "② dnsmasq:53（唯一缓存 + 唯一分流层）", 13, C.accent, "start", "600")
	p[#p + 1] = txt(48, y + 46, "no-resolv · log-queries=extra · 不向上游递归", 11, C.muted)

	local bx = 52
	local by = y + 62
	local bw = 276
	local bh = 126

	p[#p + 1] = rect(bx, by, bw, bh, C.warn)
	p[#p + 1] = txt(bx + 12, by + 22, "A. 数据库命中（国外）", 12, C.warn, "start", "600")
	p[#p + 1] = txt(bx + 12, by + 44, "dnschain-split.conf", 10, C.muted)
	p[#p + 1] = txt(bx + 12, by + 60, "23,745 条 server=", 10, C.muted)
	p[#p + 1] = txt(bx + 12, by + 82, "→ 127.0.0.1#5336", 11, C.warn, "start", "600")
	p[#p + 1] = txt(bx + 12, by + 102, "同时写 nftset → blacklist", 10, C.muted)

	p[#p + 1] = rect(bx + bw + 14, by, bw, bh, C.ok)
	p[#p + 1] = txt(bx + bw + 26, by + 22, "B. 自定义国内", 12, C.ok, "start", "600")
	p[#p + 1] = txt(bx + bw + 26, by + 44, "dom_domestic（用户手写）", 10, C.muted)
	p[#p + 1] = txt(bx + bw + 26, by + 60, "优先级最高", 10, C.muted)
	p[#p + 1] = txt(bx + bw + 26, by + 82, "→ 127.0.0.1#5353", 11, C.ok, "start", "600")
	p[#p + 1] = txt(bx + bw + 26, by + 102, "并写入 china 集强制直连", 10, C.muted)

	local cx = bx + (bw + 14) * 2
	p[#p + 1] = rect(cx, by, bw, bh, C.border)
	p[#p + 1] = txt(cx + 12, by + 22, "C. 未命中（默认）", 12, C.text, "start", "600")
	p[#p + 1] = txt(cx + 12, by + 44, "server=127.0.0.1#5353", 10, C.muted)
	p[#p + 1] = txt(cx + 12, by + 60, "（dnsmasq 全局默认）", 10, C.muted)
	p[#p + 1] = txt(cx + 12, by + 82, "→ 127.0.0.1#5353", 11, C.text, "start", "600")
	p[#p + 1] = txt(cx + 12, by + 102, "绝大多数国内域名走这里", 10, C.muted)

	y = y + dh

	p[#p + 1] = down(190, y, y + 26, C.ok)
	p[#p + 1] = down(770, y, y + 26, C.warn)
	y = y + 26

	-- ── ③ 两个 dnsproxy ──────────────────────────────────────
	local ph = 158
	p[#p + 1] = rect(x0, y, 320, ph, C.ok)
	p[#p + 1] = txt(48, y + 24, "③a dnsproxy :5353（直连）", 12, C.ok, "start", "600")
	p[#p + 1] = txt(48, y + 48, "上游：tls://223.5.5.5", 10, C.muted)
	p[#p + 1] = txt(48, y + 64, "      tls://223.6.6.6", 10, C.muted)
	p[#p + 1] = txt(48, y + 80, "      https://dns.alidns.com/dns-query", 10, C.muted)
	p[#p + 1] = txt(48, y + 104, "无缓存（缓存只在 dnsmasq）", 10, C.muted)
	p[#p + 1] = txt(48, y + 126, "--fallback 127.0.0.1:5336", 10, C.warn)
	p[#p + 1] = txt(48, y + 144, "（直连不可用时自动改走代理）", 10, C.muted)

	p[#p + 1] = rect(610, y, 320, ph, C.warn)
	p[#p + 1] = txt(628, y + 24, "③b dnsproxy :5336（代理）", 12, C.warn, "start", "600")
	p[#p + 1] = txt(628, y + 48, "上游：https://dns.google/dns-query", 10, C.muted)
	p[#p + 1] = txt(628, y + 64, "      https://cloudflare-dns.com/dns-query", 10, C.muted)
	p[#p + 1] = txt(628, y + 88, "via_proxy=1 → 经 :1234 出站", 10, C.warn)
	p[#p + 1] = txt(628, y + 110, "必须 DoH(443)，不能 DoT(853)", 10, C.muted)
	p[#p + 1] = txt(628, y + 132, "（落地节点到 853 全部被 reset）", 10, C.muted)

	y = y + ph

	p[#p + 1] = down(190, y, y + 26, C.ok)
	p[#p + 1] = down(770, y, y + 26, C.warn)
	y = y + 26

	-- ── ④ 出网判定 ───────────────────────────────────────────
	local wh = 174
	p[#p + 1] = rect(x0, y, fw, wh, C.accent)
	p[#p + 1] = txt(48, y + 24,
		"④ 出网判定：nft 的 ss_spec_wan_ac（按目标 IP 判断，与 DNS 无关）",
		12, C.accent, "start", "600")

	local rules = {
		{ "ip daddr @blacklist   jump ss_spec_wan_fw", "走代理", C.warn },
		{ "ip daddr @whitelist   return", "直连", C.ok },
		{ "ip daddr @china       return", "直连", C.ok },
		{ "（兜底）return _DC_DIRECT_DEFAULT_", "直连", C.ok },
	}
	local ry = y + 52
	for _, r in ipairs(rules) do
		p[#p + 1] = txt(64, ry, r[1], 10, C.text)
		p[#p + 1] = txt(620, ry, r[2], 10, r[3], "start", "600")
		ry = ry + 22
	end

	p[#p + 1] = txt(48, y + 158,
		"⚠️ 兜底已从「走代理」改为「直连」（v0.23.2）—— 原因见下方数据流图", 10, C.warn)

	y = y + wh

	p[#p + 1] = down(190, y, y + 26, C.ok)
	p[#p + 1] = down(770, y, y + 26, C.warn)
	y = y + 26

	-- ── ⑤ 出网 ───────────────────────────────────────────────
	local eh = 72
	p[#p + 1] = rect(x0, y, 320, eh, C.ok)
	p[#p + 1] = txt(48, y + 24, "⑤a 直连出网（pppoe-wan，MTU 1492）", 11, C.ok, "start", "600")
	p[#p + 1] = txt(48, y + 48, "客户机 → 运营商 → 目标（国内 CDN 正常）", 10, C.muted)

	p[#p + 1] = rect(610, y, 320, eh, C.warn)
	p[#p + 1] = txt(628, y + 24, "⑤b v2ray :1234 → 海外节点", 11, C.warn, "start", "600")
	p[#p + 1] = txt(628, y + 48, "VLESS + WS + TLS（新加坡节点）", 10, C.muted)

	y = y + eh + 26

	p[#p + 1] = txt(W / 2, y,
		"关键：DNS 层的分流决策 与 nft 层的出站判定是两套独立机制，" ..
		"两者不一致时会出现「DNS 说直连、实际走代理」。", 10, C.muted, "middle")

	p[#p + 1] = '</svg>'
	return table.concat(p, "\n")
end

-- ------------------------------------------------------------
-- 图 2：数据库与名单的数据流向
-- ------------------------------------------------------------
function M.flow()
	local W, H = 960, 668
	local p = { svg_open(W, H, "data-flow") }

	p[#p + 1] = txt(W / 2, 28, "数据库与名单的数据流向", 18, C.text, "middle", "600")
	p[#p + 1] = txt(W / 2, 50,
		"每一列的箭头都对应一次真实的文件读写，数字来自实测快照", 12, C.muted, "middle")

	local colw = 288
	local gap = 22
	local x1 = 24
	local x2 = x1 + colw + gap
	local x3 = x2 + colw + gap

	local y = 76
	p[#p + 1] = txt(x1 + math.floor(colw / 2), y, "① 数据源", 12, C.muted, "middle", "600")
	p[#p + 1] = txt(x2 + math.floor(colw / 2), y, "② 仓库 overlay / 生成器", 12, C.muted, "middle", "600")
	p[#p + 1] = txt(x3 + math.floor(colw / 2), y, "③ 运行时产物", 12, C.muted, "middle", "600")

	y = y + 16
	local bh = 96

	-- 左列：三个数据源
	p[#p + 1] = rect(x1, y, colw, bh, C.warn)
	p[#p + 1] = txt(x1 + 12, y + 22, "gfw_list.conf", 11, C.warn, "start", "600")
	p[#p + 1] = txt(x1 + 12, y + 44, "23,771 条 server=", 10, C.muted)
	p[#p + 1] = txt(x1 + 12, y + 60, "由 SSR-Plus 维护", 10, C.muted)
	p[#p + 1] = txt(x1 + 12, y + 82, "来源：订阅更新 / 手动导入", 10, C.muted)

	p[#p + 1] = rect(x1, y + bh + 14, colw, bh, C.ok)
	p[#p + 1] = txt(x1 + 12, y + bh + 36, "china_ssr.txt", 11, C.ok, "start", "600")
	p[#p + 1] = txt(x1 + 12, y + bh + 58, "4,316 条 CIDR", 10, C.muted)
	p[#p + 1] = txt(x1 + 12, y + bh + 74, "（精简版，覆盖不全）", 10, C.warn)
	p[#p + 1] = txt(x1 + 12, y + bh + 96, "APNIC 完整版有 8,797 条", 10, C.muted)

	p[#p + 1] = rect(x1, y + (bh + 14) * 2, colw, bh, C.accent)
	p[#p + 1] = txt(x1 + 12, y + (bh + 14) * 2 + 22, "UCI 配置", 11, C.accent, "start", "600")
	p[#p + 1] = txt(x1 + 12, y + (bh + 14) * 2 + 44, "/etc/config/dnschain", 10, C.muted)
	p[#p + 1] = txt(x1 + 12, y + (bh + 14) * 2 + 60, "dom_domestic", 10, C.muted)
	p[#p + 1] = txt(x1 + 12, y + (bh + 14) * 2 + 76, "dom_foreign", 10, C.muted)
	p[#p + 1] = txt(x1 + 12, y + (bh + 14) * 2 + 96, "（手写 + 页面保存）", 10, C.muted)

	-- 中列：生成器
	p[#p + 1] = rect(x2, y, colw, bh, C.border)
	p[#p + 1] = txt(x2 + 12, y + 22, "applechina.conf", 11, C.text, "start", "600")
	p[#p + 1] = txt(x2 + 12, y + 44, "173 条 Apple 域名", 10, C.muted)
	p[#p + 1] = txt(x2 + 12, y + 60, "→ 127.0.0.1#5353（直连）", 10, C.ok)
	p[#p + 1] = txt(x2 + 12, y + 82, "原文件是 114.114.114.114", 10, C.muted)

	p[#p + 1] = rect(x2, y + bh + 14, colw, bh, C.border)
	p[#p + 1] = txt(x2 + 12, y + bh + 36, "dnschain.sh", 11, C.text, "start", "600")
	p[#p + 1] = txt(x2 + 12, y + bh + 58, "生成器 + 归属判定", 10, C.muted)
	p[#p + 1] = txt(x2 + 12, y + bh + 74, "dc_gen_dnsmasq_split()", 10, C.muted)
	p[#p + 1] = txt(x2 + 12, y + bh + 90, "dc_gen_db_domains()", 10, C.muted)

	p[#p + 1] = rect(x2, y + (bh + 14) * 2, colw, bh, C.border)
	p[#p + 1] = txt(x2 + 12, y + (bh + 14) * 2 + 22, "dnschain-reconcile", 11, C.text, "start", "600")
	p[#p + 1] = txt(x2 + 12, y + (bh + 14) * 2 + 44, "每轮收敛", 10, C.muted)
	p[#p + 1] = txt(x2 + 12, y + (bh + 14) * 2 + 60, "重放不变量 + 重建分流", 10, C.muted)
	p[#p + 1] = txt(x2 + 12, y + (bh + 14) * 2 + 80, "末尾：修出站兜底", 10, C.ok)

	-- 右列：运行时产物
	p[#p + 1] = rect(x3, y, colw, bh, C.accent)
	p[#p + 1] = txt(x3 + 12, y + 22, "dnschain-split.conf", 11, C.accent, "start", "600")
	p[#p + 1] = txt(x3 + 12, y + 44, "47,496 行", 10, C.text, "start", "600")
	p[#p + 1] = txt(x3 + 12, y + 60, "23,745 条 server=", 10, C.warn)
	p[#p + 1] = txt(x3 + 12, y + 76, "23,745 条 nftset=", 10, C.warn)
	p[#p + 1] = txt(x3 + 12, y + 96, "唯一 server= 来源", 10, C.muted)

	p[#p + 1] = rect(x3, y + bh + 14, colw, bh, C.accent)
	p[#p + 1] = txt(x3 + 12, y + bh + 36, "nft 集合 inet ss_spec", 11, C.accent, "start", "600")
	p[#p + 1] = txt(x3 + 12, y + bh + 58, "china      3,379 条", 10, C.ok)
	p[#p + 1] = txt(x3 + 12, y + bh + 74, "blacklist     20 条", 10, C.warn)
	p[#p + 1] = txt(x3 + 12, y + bh + 90, "whitelist      0 条", 10, C.muted)

	p[#p + 1] = rect(x3, y + (bh + 14) * 2, colw, bh, C.accent)
	p[#p + 1] = txt(x3 + 12, y + (bh + 14) * 2 + 22, "客户端诊断日志", 11, C.accent, "start", "600")
	p[#p + 1] = txt(x3 + 12, y + (bh + 14) * 2 + 44, "client-flow.log", 10, C.muted)
	p[#p + 1] = txt(x3 + 12, y + (bh + 14) * 2 + 60, "client-fail.log", 10, C.muted)
	p[#p + 1] = txt(x3 + 12, y + (bh + 14) * 2 + 76, "autofix.log", 10, C.muted)
	p[#p + 1] = txt(x3 + 12, y + (bh + 14) * 2 + 96, "（v0.23.0 起）", 10, C.muted)

	-- 连线（曲线，控制点在两点之间）
	local row1y = y + math.floor(bh / 2)
	local row2y = y + bh + 14 + math.floor(bh / 2)
	local row3y = y + (bh + 14) * 2 + math.floor(bh / 2)

	-- 连线只画在列间空隙里（x1+colw → x2 之间、x2+colw → x3 之间）。
	--
	-- 原写法从 x1+colw 直接拉到 x3，会**穿过中列方框** ——
	-- 视觉上像把中列内容划掉。分两段画，绕开中列。
	local g1 = x2 - 2          -- 第一段终点（中列左缘前）
	local g2 = x2 + colw + 2   -- 第二段起点（中列右缘后）
	p[#p + 1] = line(x1 + colw, row1y, g1, row1y, C.warn)
	p[#p + 1] = line(x2 + colw, row1y, x3, row1y, C.warn)
	p[#p + 1] = line(x1 + colw, row2y, g1, row2y, C.ok)
	p[#p + 1] = line(x2 + colw, row2y, x3, row2y, C.ok)
	p[#p + 1] = line(x1 + colw, row3y, g1, row3y, C.accent)
	p[#p + 1] = line(x2 + colw, row3y, x3, row3y, C.accent)

	y = y + (bh + 14) * 3 + 20

	-- 要点
	p[#p + 1] = rect(24, y, W - 48, 176, C.border)
	p[#p + 1] = txt(44, y + 26, "数据流的关键约束", 12, C.text, "start", "600")

	local notes = {
		"① gfw_list.conf（23,771 域名）→ dnschain-split.conf 生成 23,745 条 server=/域名/127.0.0.1#5336，",
		"    同时生成等量 nftset 规则 —— 域名解析结果自动写入 blacklist 集合，供 nft 判断出站。",
		"",
		"② china_ssr.txt（4,316 CIDR）→ chinaipset.sh 灌入 nft 的 china 集合（实测 3,379 条，auto-merge 合并）。",
		"    该列表覆盖不全：实测阿里云 CDN 的 47.239.100.208 不在其中，连 APNIC 官方 8,797 条也不收录。",
		"",
		"③ 出站判定与 DNS 判定是两套机制：DNS 决定「用哪条链解析」，nft 决定「用哪条链出网」。",
		"    两者不一致时（DNS 说直连、IP 不在 china 集合）会走代理 —— 这正是 v0.23.2 修的问题。",
		"",
		"④ 修复方式：兜底从 jump ss_spec_wan_fw 改为 return，即「未列入 gfw 的 IP 默认直连」。",
	}
	local ny = y + 52
	for _, n in ipairs(notes) do
		if n ~= "" then
			p[#p + 1] = txt(44, ny, n, 10, C.muted)
		end
		ny = ny + 16
	end

	p[#p + 1] = '</svg>'
	return table.concat(p, "\n")
end

-- ------------------------------------------------------------
-- 图 3：一个查询的完整生命周期（时序）
-- ------------------------------------------------------------
function M.lifecycle()
	local W, H = 960, 856
	local p = { svg_open(W, H, "query-lifecycle") }

	p[#p + 1] = txt(W / 2, 28, "一个查询的完整生命周期", 18, C.text, "middle", "600")
	p[#p + 1] = txt(W / 2, 50,
		"以客户机查询 www.google.com 为例（国外域名，走代理链）", 12, C.muted, "middle")

	local steps = {
		{ n = "1", who = "客户机", what = "发出 UDP 53 查询",
		  detail = "目标 192.168.3.254:53",
		  file = "—", fail = "无响应 → 客户机 5 秒超时", tone = C.muted },
		{ n = "2", who = "fw4", what = "dns_intercept_lan 劫持",
		  detail = "把发往任意地址的 53 端口重定向到本机 dnsmasq",
		  file = "nft inet fw4", fail = "规则缺失 → 客户机绕过分流直连外部 DNS", tone = C.accent },
		{ n = "3", who = "dnsmasq", what = "查缓存",
		  detail = "命中则直接回复，不走上游（日志动作 cached）",
		  file = "内存缓存", fail = "—", tone = C.ok },
		{ n = "4", who = "dnsmasq", what = "匹配 server=/域名/",
		  detail = "google.com 在 split.conf 里 → 127.0.0.1#5336",
		  file = "dnschain-split.conf（47,496 行）",
		  fail = "未命中 → 用全局默认 server=127.0.0.1#5353", tone = C.warn },
		{ n = "5", who = "dnsproxy :5336", what = "DoH 加密查询",
		  detail = "https://dns.google/dns-query，经 :1234 代理出站",
		  file = "—", fail = "上游不可用 → 返回 SERVFAIL", tone = C.warn },
		{ n = "6", who = "dnsmasq", what = "回复客户机 + 写 nftset",
		  detail = "把解析出的 IP 写入 blacklist 集合（nftset 规则）",
		  file = "nft set blacklist", fail = "nftset 未生效 → 出站按 IP 判断会走直连", tone = C.warn },
		{ n = "7", who = "nft", what = "出站判定（按目标 IP）",
		  detail = "ip daddr @blacklist → jump ss_spec_wan_fw → redirect :1234",
		  file = "inet ss_spec", fail = "IP 不在 blacklist → 走直连（可能被墙）", tone = C.warn },
		{ n = "8", who = "v2ray :1234", what = "经海外节点出网",
		  detail = "VLESS + WS + TLS → 新加坡节点 → 目标",
		  file = "—", fail = "节点不可用 → 连接超时", tone = C.warn },
	}

	local y = 80
	local rowh = 96

	for i, s in ipairs(steps) do
		p[#p + 1] = string.format(
			'<circle cx="46" cy="%d" r="15" fill="none" stroke="%s" stroke-width="1.5"/>',
			math.floor(y + 30), s.tone)
		p[#p + 1] = txt(46, y + 35, s.n, 13, s.tone, "middle", "600")

		p[#p + 1] = rect(72, y, W - 100, rowh - 12, s.tone)

		p[#p + 1] = txt(90, y + 24, s.who, 12, s.tone, "start", "600")
		p[#p + 1] = txt(240, y + 24, s.what, 12, C.text, "start", "600")
		p[#p + 1] = txt(90, y + 44, s.detail, 10, C.muted)
		p[#p + 1] = txt(90, y + 62, "文件/对象：" .. s.file, 10, C.muted)
		p[#p + 1] = txt(90, y + 80, "失败表现：" .. s.fail, 10,
			s.fail == "—" and C.muted or C.warn)

		if i < #steps then
			p[#p + 1] = line(46, y + 45, 46, y + rowh + 2, C.border, 1.5, "4 3")
		end

		y = y + rowh
	end

	p[#p + 1] = '</svg>'
	return table.concat(p, "\n")
end

return M
