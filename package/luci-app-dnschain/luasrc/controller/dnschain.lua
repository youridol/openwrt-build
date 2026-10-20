module("luci.controller.dnschain", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/dnschain") then
		return
	end

	entry({"admin", "network", "dns_chain"},
		cbi("dnschain/general"),
		_("DNS 链路"), 45).dependent = false
end
