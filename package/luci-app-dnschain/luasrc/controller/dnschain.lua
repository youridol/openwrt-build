module("luci.controller.dnschain", package.seeall)

-- 显式 require 而不是依赖 dispatcher 注入的全局 nixio（v0.14.4 修 L9）。
-- 正常请求路径下 nixio 全局可用，但脱离 dispatcher 的单元测试 /
-- CLI 环境会抛 attempt to index global 'nixio' (a nil value)，
-- 而 index() 里没有 pcall，异常会冒到 dispatcher。
local fs = require "nixio.fs"

function index()
	if not fs.access("/etc/config/dnschain") then
		return
	end

	-- 侧边栏位置：服务 → DNS 分流，紧接在「ShadowSocksR Plus+」下一行。
	--
	-- 排序依据（实测 2026-10-22，浏览器侧边栏实际顺序）：
	--   ShadowSocksR Plus+  order=10   ← /usr/lib/lua/luci/controller/shadowsocksr.lua
	--   DNS 分流            order=20   ← 本页（v0.12.1 从「网络」移到这里）
	--   动态 DNS            order=59
	--   DNS Proxy           order=60
	--   带宽监控            order=80
	--   网络唤醒            order=90
	--
	-- ⚠️ SSR-Plus 的 order 定义在 Lua controller（不是 menu.d JSON），
	-- 取值 10 是它 entry() 的最后一个参数。要保持在它下一行，
	-- 本页 order 必须满足 10 < order < 59；取 20 留出余量。
	--
	-- ⚠️ 不要设 page.leaf = true。
	-- v0.12.0 曾加上它（本意是「每次进入都重新渲染」），结果侧边栏里
	-- 这一项直接消失。实测原因是 leaf 节点在生成的菜单树 JSON 里带
	-- `"wildcard": true`，而 LuCI 前端把 wildcard 节点当作「占位/通配」
	-- 不渲染成菜单链接：
	--   "nodespec": { …, "order": 20, "title": "DNS 分流",
	--                 "wildcard": true, "readonly": false }
	-- 去掉 leaf 后侧边栏正常显示，且 CBI 页面本来就不会被缓存
	-- （dispatcher 每次请求都重新执行 controller 与 model）。
	--
	-- ⚠️ v0.16.4 全局改名：「DNS 链路」→「DNS 分流」（只改显示文案，
	--    路由名 dns_chain 与包名 luci-app-dnschain 保持不变，理由见
	--    CHANGELOG 对应版本段）。
	local page = entry({"admin", "services", "dns_chain"},
		cbi("dnschain/general"),
		_("DNS 分流"), 20)
	page.dependent = false

	-- ── 自动补全的行内操作（v0.24.0，ADR-0010）──────────────────
	--
	-- 为什么需要这个 action（而不是用 CBI 的 Button）：
	--   「已学域名」「已学 IP 段」两张表的每一行都要两个动作
	--   （钉住 / 移除），而 CBI 的 Button 只能挂在 section 上，
	--   无法区分「哪一行」。Table + Button 的做法要求每行是一个
	--   UCI section，而这些行来自 list 选项与一个文本文件。
	--
	--   改用 GET + 独立路由：表格里渲染 <a href="...learn?act=..&v=..">，
	--   服务端执行后 302 回原页面。GET 在这里是安全的 ——
	--   它不改变「正在编辑的表单」，只改自动生成的那部分数据。
	--
	-- ⚠️ 必须带 csrf 校验：虽然是 GET，但它会写 UCI。
	--    LuCI 的 dispatcher 对 GET 不自动校验 token，
	--   故这里显式调 luci.http.formvalue("token") 比对。
	entry({"admin", "services", "dns_chain", "learn"}, call("action_learn"), nil).leaf = true
end

-- 行内操作的处理函数
--
-- act 取值：
--   pin          把自动条目转成手写（side 必须给）
--   remove       从自动列表删掉该域名
--   remove_cidr  从 learn-cidr.txt 删掉该 IP 段
--
-- 所有参数都经 model 层的白名单校验与 shell 转义，
-- 本函数只负责分发与跳转。
function action_learn()
	local ds = require "luci.model.cbi.dnschain.dnschain"

	-- 只接受已登录会话：本 action 会写配置，不能匿名可调
	if not luci.dispatcher.context.authsession then
		luci.http.status(403, "Forbidden")
		return
	end

	local act = luci.http.formvalue("act") or ""
	local v   = luci.http.formvalue("v") or ""
	local side = luci.http.formvalue("side") or ""

	local ok, msg

	if act == "pin" then
		ok, msg = ds.learn_pin(v, side)
	elseif act == "remove" then
		ok, msg = ds.learn_remove(v)
	elseif act == "remove_cidr" then
		ok, msg = ds.learn_remove_cidr(v)
	else
		ok, msg = false, "未知操作"
	end

	-- 结果通过 URL 参数带回页面显示（CBI 页面重新渲染时会读它）
	--
	-- 为什么不用 session flash：本固件的 LuCI 没有稳定的 flash 接口，
	-- 而 URL 参数在刷新后仍可见 —— 用户点完按钮能立刻确认结果，
	-- 这正是「禁止静默失败」的要求。
	luci.http.redirect(luci.dispatcher.build_url(
		"admin", "services", "dns_chain") ..
		"?learn_msg=" .. luci.util.urlencode((ok and "✓ " or "✗ ") .. tostring(msg or "")))
end
