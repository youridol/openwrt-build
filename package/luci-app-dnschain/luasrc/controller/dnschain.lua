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

	-- 侧边栏位置：服务 → DNS 链路，紧接在「ShadowSocksR Plus+」下一行。
	--
	-- 排序依据（实测 2026-10-22，浏览器侧边栏实际顺序）：
	--   ShadowSocksR Plus+  order=10   ← /usr/lib/lua/luci/controller/shadowsocksr.lua
	--   DNS 链路            order=20   ← 本页（v0.12.1 从「网络」移到这里）
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
	--   "nodespec": { …, "order": 20, "title": "DNS 链路",
	--                 "wildcard": true, "readonly": false }
	-- 去掉 leaf 后侧边栏正常显示，且 CBI 页面本来就不会被缓存
	-- （dispatcher 每次请求都重新执行 controller 与 model）。
	local page = entry({"admin", "services", "dns_chain"},
		cbi("dnschain/general"),
		_("DNS 链路"), 20)
	page.dependent = false
end
