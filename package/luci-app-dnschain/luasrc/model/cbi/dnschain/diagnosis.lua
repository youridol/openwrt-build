-- diagnosis.lua —— 从自检证据推导「为什么坏 / 会怎样 / 怎么修」
--
-- ── 这个模块解决什么问题 ──────────────────────────────────────────
--
-- 用户要求：「我需要动态看到链路问题，当自动化程序解决不了的时候，
-- 链路出现问题可以让用户可视化快速解决问题」。
--
-- 自检（dnschain-selftest）能回答「哪一项没通过」，但答案是给机器看的
-- 证据串，例如：
--
--     7 FAIL 端口所有权无冲突 — pdnsd_enable=4（应为 0 或 7）
--     19 PASS 改道通道已就绪 — servers-file=... （已进 dnsmasq 配置）
--
-- 用户看到「pdnsd_enable=4」并不知道这意味着什么、会影响什么、该敲什么命令。
-- 本模块负责把**证据串**翻译成三样东西：
--
--     症状（symptom）—— 用一句话说清哪儿坏了
--     影响（impact） —— 坏了会导致什么用户可见的后果
--     排查（fix）    —— 可直接复制的命令
--
-- ── 为什么用「规则推导」而不是「为每个分支写死文案」─────────────
--
-- dnschain-selftest 有 **60 个 emit 调用点**、20 个检查项。
-- 若给每个 FAIL 分支手写 cause/impact/fix：
--
--   ① 等于把「写死」从 Lua 搬到 shell，且每处都可能与实际不符；
--   ② **新增检查项时必然漏写** → 新失败静默无提示，比不写更糟。
--
-- 而 evidence（emit 第 4 参数）本身**已经是动态的真实探测结果**。
-- 缺的不是原因文本，而是「从证据到症状」的推导。推导规则只有十余条，
-- 覆盖绝大多数失败形态；剩下推导不出的，本模块**诚实地说不知道**
-- （见 §4「未识别的失败模式」）。
--
-- ── 边界：宁可说不知道，也不编 ────────────────────────────────────
--
-- 错误诊断比没有诊断更糟：用户会照着错的指引去改配置，把好链路改坏。
-- 所以规则未命中时，本模块只输出「未识别的失败模式」+ 证据原文 + 复现命令，
-- 绝不生成一句「看起来合理」的推测。
--
-- ── 与其它模块的分工 ──────────────────────────────────────────────
--
--   dnschain.lua  —— 采集数据（调脚本、解析输出）
--   diagnosis.lua —— **本模块**：把证据翻译成人话（纯函数，无 IO）
--   diagrams.lua  —— 把数据画成图（只负责几何与视觉，不含业务判断）
--   general.lua   —— 组装页面（调上面三者）
--
-- 本模块是**纯函数**：不调 sys.exec、不读文件、不碰 UCI。
-- 这样它可以被单独测试，也不会因为一次网络/磁盘抖动而改变诊断结论。

local i18n = require "luci.i18n"
local translate = i18n.translate

local D = {}

-- ----------------------------------------------------------------------
-- 1. 阶段定义（从 general.lua 迁来，v0.18.0）
--
-- ── 为什么把 STAGES 放在这里 ────────────────────────────────────
--
-- 它原先在 general.lua 的 `_live_diag_map` 里（页面组装代码中间）。
-- 但它是**业务知识**（哪几项检查属于哪条链路阶段），而 general.lua
-- 只是组装页面。放到本模块后：
--
--   · general.lua 调 D.stages() 取定义
--   · 本模块的兜底逻辑（§3）与它同源，不会漂移
--   · 断言可以直接测「STAGES 是否覆盖了 selftest 的全部编号」
--
-- ⚠️ items 里的编号必须与 dnschain-selftest 的 `emit <序号>` 一一对应。
--    改 selftest 的项号时必须同步这里，否则该阶段会漏项（或把别的项算进来）。
--    tools/verify-dnschain-domains.sh 有断言检查编号覆盖完整性。
-- ----------------------------------------------------------------------
local STAGES = {
	{ id = "client",   label = "客户机入口", items = { 1 } },
	{ id = "dnsmasq",  label = "dnsmasq",    items = { 3, 15, 16 } },
	{ id = "domestic", label = "国内链路",   items = { 4, 5, 8, 9 } },
	{ id = "foreign",  label = "国外链路",   items = { 10, 11, 12 } },
	{ id = "proxy",    label = "代理与分流", items = { 13 } },
	{ id = "split",    label = "分流规则",   items = { 2, 17, 18 } },
	{ id = "fw4",      label = "fw4",        items = { 14, 20 } },
	{ id = "policy",   label = "双栈与端口", items = { 6, 7, 19 } },
}

--- 阶段定义（返回副本，防止调用方改到内部表）
function D.stages()
	local out = {}
	for i, st in ipairs(STAGES) do
		local items = {}
		for j, no in ipairs(st.items) do items[j] = no end
		out[i] = { id = st.id, label = translate(st.label), items = items }
	end
	return out
end

-- ----------------------------------------------------------------------
-- 2. 证据 → 症状 推导规则
--
-- ── 规则的写法 ──────────────────────────────────────────────────
--
--   pattern  Lua 模式（对证据串做 find）
--   symptom  症状（一句话说清哪儿坏了）
--   impact   影响（用户可见的后果）
--   fix      排查命令（可直接复制）
--
-- ── 顺序敏感 ────────────────────────────────────────────────────
--
-- 规则**从上往下匹配，命中即停**。所以：
--   · 更具体的规则必须排在更笼统的规则前面
--   · 例如「无监听」比「应为 1」更具体，必须先匹配
--
-- ── 为什么用 `find(..., true)` 做字节精确匹配 ────────────────────
--
-- 证据串里含中文与全角符号。Lua 的字符类按**字节**工作（不按码位），
-- 用 `[^—]` 这类写法会把常用汉字的字节误排除（v0.14.4 踩过，
-- 20 项里 7 项匹配失败）。这里一律用 `find(s, 1, true)` 做纯字节匹配，
-- 不做字符类。
-- ----------------------------------------------------------------------
local RULES = {
	-- ── 进程未监听（最严重，必须排最前）────────────────────────
	{
		pattern = "无监听",
		symptom = "该段没有进程在监听端口",
		impact  = "走这一段的域名会全部解析失败（客户机表现为打不开网页）",
		fix     = "/etc/init.d/dnschain restart; netstat -lnup | grep -E ':(5353|5336)'",
	},
	{
		pattern = "未监听",
		symptom = "该段没有进程在监听端口",
		impact  = "走这一段的域名会全部解析失败",
		fix     = "/etc/init.d/dnschain restart; netstat -lnup | grep -E ':(5353|5336)'",
	},

	-- ── 端口被别的进程占用 ────────────────────────────────────
	{
		pattern = "被 PID",
		symptom = "端口被其它进程占用",
		impact  = "框架无法绑定该端口，相关域名会走错解析器或被污染",
		fix     = "netstat -lnup | grep <端口>  # 找出占用者；若是 chinadns-ng 或 mosdns 残留，停掉它",
	},
	{
		pattern = "占用",
		symptom = "端口被其它进程占用",
		impact  = "框架无法绑定该端口，相关域名会走错解析器",
		fix     = "netstat -lnup | grep <端口>",
	},

	-- ── 配置值不符合期望 ──────────────────────────────────────
	{
		pattern = "应为 1",
		symptom = "配置值与框架期望不符",
		impact  = "按该配置运行时，某条链路的行为会偏离预期",
		fix     = "/usr/bin/dnschain-selftest; /usr/bin/dnschain-reconcile  # 收敛器会写回期望值",
	},
	{
		pattern = "应为 0",
		symptom = "配置值与框架期望不符",
		impact  = "该开关会改变链路行为（例如连国内 AAAA 一起砍）",
		fix     = "/usr/bin/dnschain-reconcile  # 把键归一到框架期望值",
	},
	{
		pattern = "出现",
		symptom = "配置里出现了不该有的内容",
		impact  = "会改变分流或解析行为，且难以从页面看出",
		fix     = "grep -n '<关键词>' /var/etc/dnsmasq.conf.* /tmp/dnsmasq.d/  # 定位来源",
	},

	-- ── 文件/目录缺失 ─────────────────────────────────────────
	{
		pattern = "缺少",
		symptom = "框架需要的文件不存在",
		impact  = "依赖该文件的规则不会生效，相关域名可能走错链路",
		fix     = "/usr/bin/dnschain-reconcile  # 重新生成派生文件",
	},
	{
		pattern = "不存在",
		symptom = "框架需要的文件/对象不存在",
		impact  = "依赖它的功能不可用",
		fix     = "/usr/bin/dnschain-reconcile",
	},

	-- ── 名单/规则问题 ─────────────────────────────────────────
	{
		pattern = "未预期端口",
		symptom = "分流规则里出现了框架之外的端口",
		impact  = "这些域名会被送到错误的上游，拿到污染答案或直接失败",
		fix     = "grep -n 'server=' /tmp/dnsmasq.d/*/dnschain-split.conf  # 找出异常行",
	},
	{
		pattern = "重复",
		symptom = "配置项重复",
		impact  = "dnsmasq 可能拒绝启动（illegal repeated keyword），或行为不确定",
		fix     = "grep -c '<关键词>' /var/etc/dnsmasq.conf.*",
	},

	-- ── 超时/网络类 ───────────────────────────────────────────
	{
		pattern = "TIMEOUT",
		symptom = "探测超时",
		impact  = "该目标在当前网络下不可达；若两条链都超时会判为 dead",
		fix     = "nslookup <域名> 127.0.0.1; curl -m 5 -sS <域名>",
	},
	{
		pattern = "SERVFAIL",
		symptom = "上游返回 SERVFAIL",
		impact  = "域名无法解析（上游故障或该域名本身有问题）",
		fix     = "nslookup <域名> 127.0.0.1; nslookup <域名> 127.0.0.1:5353  # 对比两段",
	},

	-- ── 取不到数据（不是故障，是测量失败）─────────────────────
	{
		pattern = "取不到",
		symptom = "无法取得判断所需的信息",
		impact  = "本项检查被跳过，不能据此判断链路好坏",
		fix     = "/usr/bin/dnschain-selftest  # 单独复现看完整输出",
	},
}

--- 推导一条失败项的诊断
--
-- 参数：
--   item  { no, status, name, detail }（来自 selftest 解析）
--
-- 返回：
--   { known=true,  symptom, impact, fix }  规则命中
--   { known=false, symptom, impact, fix }  未命中（诚实说不知道）
function D.explain(item)
	local detail = tostring(item and item.detail or "")

	for _, r in ipairs(RULES) do
		-- 纯字节匹配：不用字符类，避免中文多字节被拆坏
		if detail:find(r.pattern, 1, true) then
			return {
				known   = true,
				rule    = r.pattern,
				symptom = translate(r.symptom),
				impact  = translate(r.impact),
				fix     = r.fix,   -- 命令不翻译
			}
		end
	end

	-- ── 未识别的失败模式（诚实输出）────────────────────────────
	--
	-- 不编造原因。只把「我不知道」+ 原始证据 + 复现命令给用户。
	-- 这是本模块最重要的边界：错误诊断比没有诊断更糟。
	return {
		known   = false,
		rule    = nil,
		symptom = translate("未识别的失败模式"),
		impact  = translate("本页没有这条证据的推导规则，无法自动判断影响面。" ..
			"请按下方「证据」原文与复现命令人工排查。"),
		fix     = "/usr/bin/dnschain-selftest  # 单独复现，看完整输出",
	}
end

-- ----------------------------------------------------------------------
-- 3. 归组：把自检项按阶段分组，并生成兜底阶段
--
-- ── 为什么需要兜底阶段（用户要求「自动生成分支」）────────────────
--
-- STAGES 是**硬编码编号**。新增第 21 项检查时，若忘了把它加进 STAGES，
-- 它会：
--   · 不属于任何阶段 → 图中**静默消失**
--   · 而 selftest 的 SUMMARY 仍计入它 → 页面数字与图对不上
--
-- 实测：STAGES 目前恰好覆盖 1-20，无缺口。但这是**当前状态**，
-- 下一次加检查项就会破。兜底阶段保证「永远不丢项」。
--
-- 兜底阶段的标题是「其他检查」，并在描述里说明「未归入链路阶段（共 N 项）」，
-- 提示维护者该把它归到某个阶段了。
-- ----------------------------------------------------------------------
local FALLBACK_ID    = "other"
local FALLBACK_LABEL = "其他检查"

--- 把自检结果按阶段归组
--
-- 参数：items —— selftest 解析出的 { {no, status, name, detail}, ... }
-- 返回：
--   stages      每个阶段 { id, label, tone, n_pass, n_fail, n_skip,
--                         evidence, first_bad, items }
--   fallback    兜底阶段（无未归组项时为 nil）
--   unassigned  未归组的编号列表（供断言与调试）
function D.group(items)
	local by_no = {}
	for _, it in ipairs(items or {}) do
		local no = tonumber(it.no) or 0
		if no > 0 then by_no[no] = it end
	end

	local claimed = {}
	local out = {}

	-- 计算一个阶段的最差状态
	local function summarize(no_list)
		local n_pass, n_fail, n_skip = 0, 0, 0
		local first_bad = nil
		local members = {}
		for _, no in ipairs(no_list) do
			local it = by_no[no]
			if it then
				members[#members + 1] = it
				claimed[no] = true
				if it.status == "PASS" then
					n_pass = n_pass + 1
				elseif it.status == "SKIP" then
					n_skip = n_skip + 1
				else
					n_fail = n_fail + 1
					if not first_bad then first_bad = it end
				end
			end
		end
		local tone = "ok"
		if n_fail > 0 then tone = "bad"
		elseif n_skip > 0 then tone = "warn" end
		return tone, n_pass, n_fail, n_skip, first_bad, members
	end

	-- 证据：优先显示失败项的证据，否则显示本阶段第一项有证据的
	local function pick_evidence(members, first_bad)
		if first_bad then
			return tostring(first_bad.detail or "")
		end
		for _, it in ipairs(members) do
			if it.detail and it.detail ~= "" then
				return tostring(it.detail)
			end
		end
		return ""
	end

	for _, st in ipairs(STAGES) do
		local tone, np, nf, ns, first_bad, members = summarize(st.items)
		out[#out + 1] = {
			id        = st.id,
			label     = translate(st.label),
			tone      = tone,
			n_pass    = np,
			n_fail    = nf,
			n_skip    = ns,
			evidence  = pick_evidence(members, first_bad),
			first_bad = first_bad,
			items     = members,
		}
	end

	-- ── 兜底：未被任何阶段认领的编号 ───────────────────────────
	local unassigned = {}
	for no, it in pairs(by_no) do
		if not claimed[no] then
			unassigned[#unassigned + 1] = it
		end
	end
	table.sort(unassigned, function(a, b)
		return (tonumber(a.no) or 0) < (tonumber(b.no) or 0)
	end)

	local fallback = nil
	if #unassigned > 0 then
		local n_pass, n_fail, n_skip = 0, 0, 0
		local first_bad = nil
		local nos = {}
		for _, it in ipairs(unassigned) do
			nos[#nos + 1] = it.no
			if it.status == "PASS" then
				n_pass = n_pass + 1
			elseif it.status == "SKIP" then
				n_skip = n_skip + 1
			else
				n_fail = n_fail + 1
				if not first_bad then first_bad = it end
			end
		end
		local tone = "ok"
		if n_fail > 0 then tone = "bad"
		elseif n_skip > 0 then tone = "warn" end

		fallback = {
			id        = FALLBACK_ID,
			label     = translate(FALLBACK_LABEL),
			tone      = tone,
			n_pass    = n_pass,
			n_fail    = n_fail,
			n_skip    = n_skip,
			evidence  = pick_evidence(unassigned, first_bad),
			first_bad = first_bad,
			items     = unassigned,
			-- 这句会显示在图节点副标题里，提示维护者去归组
			note      = string.format(
				translate("未归入链路阶段（共 %d 项）"), #unassigned),
			unassigned_nos = nos,
		}
	end

	return out, fallback, unassigned
end

--- 收集所有需要展示诊断的失败项
--
-- 返回按「阶段顺序 + 项号」排好的失败项，每项带上 D.explain 的结论。
-- 图下方的折叠明细直接用它。
function D.failures(stages, fallback)
	local out = {}

	local function push(stage)
		for _, it in ipairs(stage.items or {}) do
			if it.status ~= "PASS" and it.status ~= "SKIP" then
				local d = D.explain(it)
				out[#out + 1] = {
					stage_id    = stage.id,
					stage_label = stage.label,
					no          = it.no,
					status      = it.status,
					name        = it.name,
					detail      = it.detail,
					known       = d.known,
					rule        = d.rule,
					symptom     = d.symptom,
					impact      = d.impact,
					fix         = d.fix,
				}
			end
		end
	end

	for _, st in ipairs(stages or {}) do push(st) end
	if fallback then push(fallback) end

	return out
end

--- 全部自检编号（供断言与兜底判断）
function D.all_item_numbers()
	local nos = {}
	for _, st in ipairs(STAGES) do
		for _, no in ipairs(st.items) do
			nos[#nos + 1] = no
		end
	end
	table.sort(nos)
	return nos
end

D.FALLBACK_ID = FALLBACK_ID

return D
