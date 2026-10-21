module("luci.controller.dnschain", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/dnschain") then
		return
	end

	local page = entry({"admin", "network", "dns_chain"},
		cbi("dnschain/general"),
		_("DNS 链路"), 45)
	page.dependent = false
	-- 每次进入都重新渲染：页面内容是链路实况，缓存会显示过期状态
	page.leaf = true
end
