#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用 lupa（真实 Lua 解释器）做语法检查 + 关键函数单测。

为什么不用 `luac -p`：本机没有 luac，装一个只为语法检查不值当；
更重要的是这里还要**跑**函数，静态检查做不到。

为什么不用 mock 掉整个 LuCI：被检查的两个文件里
  · controller 依赖 luci.controller 的 entry()
  · model 依赖 nixio.fs / luci.sys / luci.http / luci.dispatcher
把这几处做成最小桩即可，其余全是真实 Lua 语义。

用法: python tools/check-dnschain-lua.py
退出码: 0 = 全部通过
"""
import os
import sys

from lupa import LuaRuntime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = [
    "package/luci-app-dnschain/luasrc/controller/dnschain.lua",
    "package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua",
    "package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua",
]

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print("  ok   %s" % msg)


def bad(msg, detail=""):
    global FAIL
    FAIL += 1
    print("  FAIL %s" % msg)
    if detail:
        print("       %s" % detail)


def check_eq(name, actual, expect):
    if actual == expect:
        ok(name)
    else:
        bad(name, "实际=[%r] 期望=[%r]" % (actual, expect))


def check_contains(name, text, sub):
    if sub in (text or ""):
        ok(name)
    else:
        bad(name, "未包含 [%s]" % sub)


def check_not_contains(name, text, sub):
    if sub in (text or ""):
        bad(name, "不应包含 [%s]" % sub)
    else:
        ok(name)


def syntax_check():
    """逐个文件做纯语法编译。"""
    L = LuaRuntime()
    for rel in FILES:
        path = os.path.join(REPO, rel)
        if not os.path.exists(path):
            bad("语法 %s" % rel, "文件不存在")
            continue
        with open(path, encoding="utf-8") as f:
            src = f.read()
        try:
            L.compile(src)
            ok("语法 %s" % rel)
        except Exception as e:
            bad("语法 %s" % rel, str(e)[:300])


def make_runtime():
    """构造一个带最小 LuCI 桩的运行时。"""
    L = LuaRuntime(unpack_returned_tuples=True)

    prelude = r"""
-- 最小 LuCI 桩：只提供被检查文件真正用到的那几个符号
--
-- module() 是 Lua 5.1 的内建（本固件是 5.1），5.4 里已移除。
-- 这里给一个等价桩：登记到 package.loaded 并返回表。
-- 注意桩**不改变调用块的 _ENV**（5.4 无法从函数内部做到），
-- 所以被测文件里的 `function index()` 会落到全局 —— 测试直接读 _G.index。
_G.module = function(name, fn)
	local t = {}
	if fn then fn(t) end
	package.loaded[name] = t
	return t
end

package.path = "./?.lua;" .. package.path

-- 记录 entry 调用，供断言使用
_G.__entries = {}
_G.entry = function(path, target, title, order)
	local e = { path = path, target = target, title = title, order = order }
	_G.__entries[#_G.__entries + 1] = e
	return e
end
_G.cbi = function(p) return { kind = "cbi", path = p } end
_G._ = function(s) return s end
_G.translate = function(s) return s end

_G.nixio = { fs = {
	access = function(p) return _G.__fs_access and _G.__fs_access[p] or false end,
	-- v0.16.5：selftest / triage_rows 加了跨请求 TTL 缓存，用 fs.stat 取 mtime。
	-- 桩必须提供 stat，否则所有走缓存的 cfgvalue 都会抛
	-- "attempt to call a nil value (field 'stat')" —— 实测一次挂掉 20 条断言。
	--
	-- 返回 nil 表示「缓存文件不存在」→ 被测代码走真跑分支，
	-- 这正是测试想要的（每次都能拿到桩数据，不会读到上一轮的缓存）。
	stat = function(p, what) return nil end,
} }

-- require 拦截：把 LuCI 的模块名映射到上面的桩。
-- 不能只设全局变量 —— 被测文件用的是 require "nixio.fs" 形式。
_G.__stub_modules = {
	["nixio.fs"] = _G.nixio.fs,
	["luci.sys"] = nil,   -- 在下面 _G.luci 建好后填
}

-- luci.i18n 模块桩
--
-- ⚠️ 必须有这一项（v0.13.0 实测踩过）。
--   `general.lua` 是 CBI 模型，靠 dispatcher 注入的全局 translate 工作 ——
--   这没问题。但 `diagrams.lua` 是被 require 的**普通模块**，
--   它必须自己 `local i18n = require "luci.i18n"` 才能拿到 translate。
--
--   原来的测试只注入了全局 translate 桩、没有 luci.i18n 模块，
--   于是 diagrams.lua 里写裸 translate 也能跑通 —— 本地全绿，
--   路由器上却是 500：`attempt to call global 'translate' (a nil value)`。
--   测试桩比真实环境宽松，正是这类问题能溜过去的原因。
--
--   现在两者都提供，并且额外加了静态断言（见 test_module_translate_import）：
--   凡是被 require 的模块文件，不得依赖全局 translate。
_G.__stub_modules["luci.i18n"] = {
	translate = function(s) return s end,
	translatef = function(s, ...) return s end,
}
local _real_require = require
_G.require = function(name)
	local m = _G.__stub_modules[name]
	if m ~= nil then return m end
	if name == "luci.sys" then return _G.luci.sys end
	if name == "luci.http" then return _G.luci.http end
	if name == "luci.dispatcher" then return _G.luci.dispatcher end
	if name == "luci.model.uci" then return _G.luci.model.uci end
	return _real_require(name)
end

_G.luci = {
	sys = {
		exec = function(cmd) return _G.__exec and _G.__exec[cmd] or "" end,
		call = function() return 0 end,
	},
	http = {},
	dispatcher = { build_url = function(t) return "/cgi-bin/luci/" .. table.concat(t, "/") end },
	config = { main = { resourcebase = "/luci-static/resources" } },
	model = { uci = { cursor = function()
		return { foreach = function() end, get = function() return nil end }
	end } },
}
"""
    L.execute(prelude)
    return L


def test_controller():
    print("=== controller/dnschain.lua ===")
    L = make_runtime()
    path = os.path.join(REPO, "package/luci-app-dnschain/luasrc/controller/dnschain.lua")
    with open(path, encoding="utf-8") as f:
        src = f.read()

    # 情况一：配置文件不存在 → 不注册任何菜单项
    L.execute("_G.__fs_access = {}")
    L.execute(src)
    L.execute("_G.__entries = {}")
    L.execute("index()")
    check_eq("缺配置时不注册菜单", L.eval("#_G.__entries"), 0)

    # 情况二：配置存在 → 注册到 服务 → DNS 分流
    L.execute("_G.__fs_access = { ['/etc/config/dnschain'] = true }")
    L.execute("_G.__entries = {}")
    L.execute("index()")
    check_eq("有配置时注册 1 个菜单", L.eval("#_G.__entries"), 1)
    check_eq("菜单位置", L.eval("table.concat(_G.__entries[1].path, '/')"),
             "admin/services/dns_chain")
    check_eq("菜单排序 20", L.eval("_G.__entries[1].order"), 20)
    # v0.16.4 全局改名：「DNS 链路」→「DNS 分流」（只改显示文案）
    check_eq("标题为「DNS 分流」", L.eval("_G.__entries[1].title"), "DNS 分流")
    # leaf 会让侧边栏该项消失（v0.12.0 实测），必须没有
    check_eq("不设 page.leaf", L.eval("_G.__entries[1].leaf"), None)


def test_model():
    print("=== model/cbi/dnschain/dnschain.lua ===")
    L = make_runtime()

    # 预置命令输出：让 model 的采集函数读到确定的值
    L.execute(r"""
_G.__exec = {
	["uci -q get dnschain.main.entry_port 2>/dev/null"] = "5353\n",
	["uci -q get dnschain.main.foreign_port 2>/dev/null"] = "5336\n",
	["uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null"] = "/var/etc/dnschain/watch.servers\n",
	["/usr/bin/dnschain-health status 2>/dev/null"] =
		"ROW github.com|db-foreign|foreign|domestic|2|0|1700000000|switch:TIMEOUT->OK|rerouted\n" ..
		"ROW www.qq.com|uncovered|domestic|domestic|0|0|1700000000|OK|ok\n" ..
		"SUM total=2 normal=1 degraded=0 rerouted=1 both_bad=0 fixed=0\n",
	["/usr/bin/dnschain-health explain 'github.com' 2>/dev/null"] =
		"DOMAIN=github.com\nCLASS=db-foreign\nPREFERRED=foreign\n" ..
		"DECISION=reroute-domestic\nREASON=国外链路不可达 → 改走直连\n",
	["/usr/bin/dnschain-health check 2>&1"] = "OK\n",
}
""")

    path = os.path.join(REPO, "package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua")
    with open(path, encoding="utf-8") as f:
        src = f.read()

    # 文件以 `return M` 结尾 —— 直接 execute 会把返回值丢掉。
    # 包成函数再调用，才能拿到那个表。
    L.execute("__chunk = function()\n" + src + "\nend")
    M = L.eval("__chunk()")
    L.globals().__M = M
    if M is None:
        bad("model 返回 M 表", "文件末尾没有 return M")
        return

    check_eq("entry_port", M.entry_port(), "5353")
    check_eq("foreign_port", M.foreign_port(), "5336")

    # 端口表解析：BusyBox netstat 的 proto 是小写、UDP 行没有 State 列
    L.execute(r"""
_G.__exec["netstat -lntup 2>/dev/null"] =
	"tcp        0      0 192.168.3.254:53   0.0.0.0:*   LISTEN  16800/dnsmasq\n" ..
	"udp        0      0 192.168.3.254:53   0.0.0.0:*           16800/dnsmasq\n" ..
	"udp        0      0 127.0.0.1:5353     0.0.0.0:*           17071/dnsproxy\n" ..
	"tcp        0      0 0.0.0.0:1234       0.0.0.0:*   LISTEN  17080/v2ray\n"
""")
    M.invalidate("listen_table")
    check_eq("端口 53/udp 归属 dnsmasq", M.port_owner("53", "udp"), "16800")
    check_eq("端口 53/tcp 归属 dnsmasq", M.port_owner("53", "tcp"), "16800")
    check_eq("端口 5353 归属 dnsproxy", M.port_owner("5353", "udp"), "17071")
    check_eq("端口 1234 归属 v2ray", M.port_owner("1234", "tcp"), "17080")
    check_eq("未监听端口返回空", M.port_owner("9999", "udp"), "")
    # UDP 行没有 State 列，仍要能取到 pid —— 这是列数不固定带来的坑
    check_eq("UDP 行无 State 仍取到 pid",
             L.eval("(function() local t = __M.listen_table(); "
                    "return t['udp:5353'] or '' end)()"), "17071")

    # v0.21.0：health_rows / health_summary / serversfile_ready / health_daemon
    # 的测试已删除 —— 这四个函数随健康改道一起移除。
    #
    # 保留 explain 与 shell_quote 的测试：explain 仍在用（单域名解释），
    # 只是入口从 dnschain-health 换成了 dnschain-selftest。
    # explain
    # v0.21.0：explain 入口从 dnschain-health 换到 dnschain-selftest。
    #
    # ⚠️ 必须把桩注入**当前这个 L**（make_runtime 建的），
    #    不能只写进后面 make_cbi_runtime 的 exec_table —— 那是另一个运行时。
    L.execute(r"""
_G.__exec["/usr/bin/dnschain-selftest explain 'github.com' 2>/dev/null"] =
	"DOMAIN=github.com\nCLASS=db-foreign\nPREFERRED=foreign\nACTIVE=foreign\n" ..
	"WATCH=0\nCUSTOM=0\nPROBE_DOMESTIC=OK\nPROBE_FOREIGN=OK\n" ..
	"ANSWER_DOMESTIC=1.2.3.4\nANSWER_FOREIGN=5.6.7.8\n" ..
	"DECISION=keep-foreign\nREASON=按归属走代理\n"
""")
    e = M.explain("github.com")
    check_eq("explain CLASS", e["CLASS"], "db-foreign")
    check_eq("explain PREFERRED", e["PREFERRED"], "foreign")

    # shell 转义：单引号必须被转成 '\''，否则可以逃逸出引号
    check_eq("转义普通串", M.shell_quote("abc"), "'abc'")
    check_eq("转义单引号", M.shell_quote("a'b"), "'a'\\''b'")
    check_contains("转义带空格", M.shell_quote("a b"), "'a b'")



CBI_STUB = r"""
-- ── 最小 CBI 桩 ──────────────────────────────────────────────
-- 目标不是模拟渲染，而是**执行**页面模型的全部代码路径，
-- 从而抓到拼错的方法名、nil 索引、未定义变量这类只在渲染时才暴露的错。
-- 只实现被真正调用的 API；调用了未实现的就会报错 —— 这正是我们要的。
_G.__opts = {}
_G.__sections = {}

local Option = {}
Option.__index = Option
function Option:value() return self end
function Option:depends() return self end
function Option:default() return self end
function Option:placeholder() return self end
function Option:datatype() return self end
function Option:rmempty() return self end
function Option:inputstyle() return self end
function Option:write() return self end
function Option:cfgvalue() return "" end

local function new_option(kind, name, title, desc)
	local o = setmetatable({ kind = kind, name = name, title = title, desc = desc }, Option)
	_G.__opts[#_G.__opts + 1] = o
	return o
end

local Section = {}
Section.__index = Section
function Section:option(kind, name, title, desc)
	return new_option(kind, name, title, desc)
end
function Section:new(kind, name, typename, title, desc)
	local s = setmetatable({
		kind = kind, name = name, typename = typename,
		title = title, desc = desc, anonymous = false, addremove = true,
	}, Section)
	_G.__sections[#_G.__sections + 1] = s
	return s
end

local Map = {}
Map.__index = Map
function Map:section(kind, name, typename, title, desc)
	return Section:new(kind, name, typename, title, desc)
end
function Map:new(config, title, desc)
	local mp = setmetatable({ config = config, title = title, desc = desc }, Map)
	mp.state_handler = function(self) return nil end
	return mp
end

_G.NamedSection = "NamedSection"
_G.TypedSection = "TypedSection"
_G.DynamicList = "DynamicList"
_G.TextValue = "TextValue"
_G.Value = "Value"
_G.Flag = "Flag"
_G.ListValue = "ListValue"
_G.Button = "Button"
_G.DummyValue = "DummyValue"

_G.Map = setmetatable({}, {
	__call = function(_, config, title, desc) return Map:new(config, title, desc) end,
})
"""


def make_cbi_runtime(exec_table):
    """构造一个能跑 general.lua 的运行时。"""
    L = make_runtime()
    L.execute(CBI_STUB)

    # general.lua 需要 luci.http.formvalue
    L.execute(r"""
_G.luci.http = {
	formvalue = function(k) return _G.__formvalue and _G.__formvalue[k] or nil end,
}
""")
    L.execute("_G.__exec = " + exec_table)

    # general.lua 里 require 的是包路径形式的模块名。
    # 真实环境靠 package.path 找文件，这里直接把两个兄弟模块
    # 预加载进 package.loaded —— 它们才是被测对象，不该被重复实现。
    def preload(name, rel):
        path = os.path.join(REPO, rel)
        with open(path, encoding="utf-8") as f:
            src = f.read()
        L.execute("__mod = function()\n" + src + "\nend")
        mod = L.eval("__mod()")
        L.execute("package.loaded[%r] = __mod_result" % name)
        L.globals().package.loaded[name] = mod

    preload("luci.model.cbi.dnschain.dnschain",
            "package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua")
    preload("luci.model.cbi.dnschain.diagrams",
            "package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua")
    # v0.18.0：general.lua 新增 require diagnosis（归组 + 证据→症状推导）。
    # 不 preload 会让整份 general.lua 加载失败 —— 实测一次挂掉 78 条断言。
    preload("luci.model.cbi.dnschain.diagnosis",
            "package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagnosis.lua")
    return L


def html_balanced(s):
    """粗检 HTML：div/table/tbody/thead/tr/td/th/span/code 标签配对。

    不追求完整解析 —— 要抓的是「拼接时漏了一个 </div>」这类错误，
    它会让后续所有 section 嵌进上一个卡片里，页面看起来完全乱掉。
    """
    import re
    stack = []
    tag_re = re.compile(r"<(/?)(div|table|tbody|thead|tr|td|th|span|code|form|svg|g)(\s[^>]*)?(/?)>")
    void = {"br", "hr", "img", "input", "meta", "link"}
    for m in tag_re.finditer(s):
        closing, tag, attrs, selfclose = m.group(1), m.group(2), m.group(3), m.group(4)
        if tag in void:
            continue
        if closing:
            if not stack or stack[-1] != tag:
                return False, "闭合 </%s> 不匹配（栈顶 %s）" % (tag, stack[-1] if stack else "空")
            stack.pop()
        elif not selfclose:
            stack.append(tag)
    if stack:
        return False, "未闭合: " + ", ".join(stack[-5:])
    return True, ""


def test_general():
    print("=== model/cbi/dnschain/general.lua（真实渲染）===")

    exec_table = r"""{
	["uci -q get dnschain.main.entry_port 2>/dev/null"] = "5353\n",
	["uci -q get dnschain.main.foreign_port 2>/dev/null"] = "5336\n",
	["uci -q get dhcp.@dnsmasq[0].serversfile 2>/dev/null"] = "/var/etc/dnschain/watch.servers\n",
	["uci -q get dnschain.domestic.domain 2>/dev/null"] = "www.baidu.com www.taobao.com\n",
	["uci -q get dnschain.foreign.domain 2>/dev/null"] = "www.google.com\n",
	["uci -q get dnschain.health.watch 2>/dev/null"] = "github.com www.qq.com\n",
	["netstat -lntup 2>/dev/null"] =
		"udp        0      0 192.168.3.254:53   0.0.0.0:*           16800/dnsmasq\n" ..
		"udp        0      0 127.0.0.1:5353     0.0.0.0:*           17071/dnsproxy\n" ..
		"udp        0      0 127.0.0.1:5336     0.0.0.0:*           17072/dnsproxy\n" ..
		"tcp        0      0 0.0.0.0:1234       0.0.0.0:*   LISTEN  17080/v2ray\n",
	-- v0.21.0：dnschain-health / dnschain-triage 已删除，
	-- 对应的模拟输出一并移除；explain 改由 selftest 提供。
	["/usr/bin/dnschain-selftest explain 'github.com' 2>/dev/null"] =
		"DOMAIN=github.com\nCLASS=db-foreign\nPREFERRED=foreign\nACTIVE=foreign\n" ..
		"WATCH=0\nCUSTOM=0\nPROBE_DOMESTIC=OK\nPROBE_FOREIGN=OK\n" ..
		"ANSWER_DOMESTIC=1.2.3.4\nANSWER_FOREIGN=5.6.7.8\n" ..
		"DECISION=keep-foreign\nREASON=按归属走代理\n",
}"""

    L = make_cbi_runtime(exec_table)
    path = os.path.join(REPO, "package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua")
    with open(path, encoding="utf-8") as f:
        src = f.read()

    L.execute("__chunk = function()\n" + src + "\nend")
    try:
        M = L.eval("__chunk()")
    except Exception as e:
        bad("general.lua 能加载", str(e)[:400])
        return

    if M is None:
        bad("general.lua 返回 map", "返回值为空")
        return
    ok("general.lua 能加载并返回 map")

    n_opts = L.eval("#_G.__opts")
    if n_opts >= 30:
        ok("注册了 %d 个 option" % n_opts)
    else:
        bad("注册的 option 数量", "只有 %d 个，疑似中途抛错" % n_opts)

    # 逐个调用 DummyValue 的 cfgvalue —— 这是真正会渲染 HTML 的那批
    L.execute("""
function __render_all()
	local out = {}
	for _, o in ipairs(_G.__opts) do
		if o.kind == "DummyValue" and type(o.cfgvalue) == "function" then
			local okc, res = pcall(o.cfgvalue, o)
			out[#out + 1] = {
				name = tostring(o.name),
				ok = okc,
				body = okc and tostring(res or "") or tostring(res),
			}
		end
	end
	return out
end
""")
    results = L.eval("__render_all()")

    n_ok = 0
    n_err = 0
    for i in range(1, len(results) + 1):
        r = results[i]
        name = r["name"]
        if not r["ok"]:
            bad("渲染 %s" % name, str(r["body"])[:300])
            n_err += 1
            continue
        body = str(r["body"])
        if body == "":
            # 空输出不算错（有些 DummyValue 在无数据时本就返回空）
            ok("渲染 %s（空）" % name)
            n_ok += 1
            continue
        good, why = html_balanced(body)
        if good:
            ok("渲染 %s（%d 字节，标签配对）" % (name, len(body)))
            n_ok += 1
        else:
            bad("渲染 %s 的 HTML 标签配对" % name, why)

    if n_err == 0:
        ok("全部 %d 个 DummyValue 渲染无异常" % len(results))

    # 关键内容必须出现（否则说明 section 没进页面）
    L.execute("_G.__formvalue = {}")
    L.execute("__chunk2 = function()\n" + src + "\nend")
    M2 = L.eval("__chunk2()")
    # 注意：这段 Lua 里有 "\n" 字面量，必须用 r""" 包，
    # 否则 Python 会把它变成真换行，Lua 侧就成了未闭合字符串。
    L.execute(r"""
function __collect_text()
	local buf = {}
	for _, o in ipairs(_G.__opts) do
		if o.kind == "DummyValue" and type(o.cfgvalue) == "function" then
			local okc, res = pcall(o.cfgvalue, o)
			if okc and res then buf[#buf + 1] = tostring(res) end
		end
	end
	return table.concat(buf, "\n")
end
""")
    alltext = str(L.eval("__collect_text()"))

    for needle, desc in [
        # ── v0.19.0：判定链路规则图已删除 ──────────────────────────
        #
        # 它画的「入口 → ①试直连 → ②试代理 → ③dead」与「DNS 分流状态」
        # 里的分流去向图语义重叠：前者讲规则、后者讲事实，用户只需后者。
        #
        # ⚠️ 规则内容本身**没有丢失** —— 它仍完整记录在
        #    docs/runtime/dns-chain.md 与分诊脚本头部注释里。
        #    因此这里断言「页面不再渲染规则图」，
        #    而不是断言图内文案（图已不存在）。
        #
        # 「单域名解释」保留（用户确认），断言它的 aria 与输入框仍在。
        ("DNS 分流去向导图", "分流去向图 aria-label"),
        # 「单域名解释」保留（用户确认）。它渲染的是输入框 + 提示文案，
        # option 的 label 不进 cfgvalue 输出，所以断言输入框的 placeholder。
        ("输入域名，例如 github.com", "单域名解释的输入框仍在（原判定链路功能保留）"),
        ("github.com", "明细表含观测域名"),
        # 原因串里的 > 会被 dg.esc 转义成 &gt; —— 这是**正确**行为
        # （域名/原因来自配置，含 < > 时不转义会让整个 SVG/HTML 解析失败）。
        # 断言按转义后的形式写，否则这条会永远失败。
        ("dc-badge", "含状态徽标"),
        ("dc-table-wrap", "表格套滚动容器"),
        # ── v0.15.0：链路拓扑图（原「实时诊断链路思维导图」）──────
        # 用户要求「加上实时诊断的链路思维导图」。
        # 它把 selftest 的 20 项按链路阶段重新分组，逐段给状态与证据。
        #
        # v0.16.3：从纵向列表改成思维导图，aria-label 改为「实时诊断链路思维导图」。
        # v0.18.0：与「解析链路」合并为一张**链路拓扑图**（ADR-0007 §2.3），
        #          aria-label 随之改为「链路拓扑图」——
        #          新图既画结构也画状态，不再是「诊断」这一个侧面。
        ("链路拓扑图", "链路拓扑图 aria-label"),
        ("dc-chain--live", "实时诊断图有独立样式类"),
        ("客户机入口", "实时诊断图含客户机入口阶段"),
        ("国外链路", "实时诊断图含国外链路阶段"),
        ("代理与分流", "实时诊断图含代理阶段"),
        ("分流规则", "实时诊断图含分流规则阶段"),
        ("双栈与端口", "实时诊断图含双栈阶段"),
        # v0.21.0：分诊结果面板已删除。分流去向图改为两档（直连/代理），
        # 断言它存在且含两档标题。
        ("走直连", "分流去向图含直连档"),
        ("走代理", "分流去向图含代理档"),
        ("dc-details", "折叠区用原生 details"),
    ]:
        check_contains("页面含 %s" % desc, alltext, needle)

    # v0.21.0：分诊三个开关（triage_enabled / triage_max / triage_conc）
    # 随分诊功能一起删除，断言反向化 —— 防止有人把它们加回来。
    for key in ["triage_enabled", "triage_max", "triage_conc"]:
        check_not_contains("分诊开关 %s 已删除" % key, src, '"%s"' % key)

    # ── v0.15.0：箭头必须全部移除 ────────────────────────────────
    #
    # 页面渲染出的 HTML 里不得出现任何 marker 定义或 marker-end 引用。
    # 这是「连线移除箭头」这条需求的**渲染级**验证 ——
    # 只查源码可能漏掉某条拼接路径（比如 general.lua 的内联链路图
    # 与 diagrams.lua 的两个函数是三处独立实现）。
    check_not_contains("页面无 marker 定义", alltext, "<marker")
    check_not_contains("页面无 marker-end 引用", alltext, "marker-end")

    # ── v0.15.0：概览与诊断已合并，且概览不再重复渲染判定链路图 ──
    #
    # 判定链路图在合并前被渲染两次（概览的「分流决策」+ 域名的「走法」），
    # 是同一函数 dg.route_map 的两份输出 —— 真正的重复。
    #
    # v0.19.0：该图已**整张删除**，故期望值从 1 改为 0。
    # 这条断言从「不得重复渲染」变成「不得再出现」——
    # 防止有人因为「图看起来少了」把它加回来。
    #
    # ⚠️ 统计口径：本测试脚本会把 general.lua 加载两次（__chunk2 之前已
    #    加载过一次），故 __opts 里每个 option 都注册了两份，直接数
    #    alltext 里的出现次数会恒为 2×N。这里改为**按 option 名去重**后
    #    再数有几个不同的 option 会渲染出判定链路图。
    n_route_opts = L.eval(r"""
(function()
	local seen, n = {}, 0
	for _, o in ipairs(_G.__opts) do
		if o.kind == "DummyValue" and type(o.cfgvalue) == "function" then
			local okc, res = pcall(o.cfgvalue, o)
			if okc and res and tostring(res):find("未知目标分诊链路图", 1, true) then
				if not seen[o.name] then
					seen[o.name] = true
					n = n + 1
				end
			end
		end
	end
	return n
end)()
""")
    check_eq("判定链路规则图已删除（不得再渲染）", int(n_route_opts), 0)

    # 空数据兜底：状态表在无数据时应给提示而不是空白
    #
    # 注意：dnschain.lua 有**请求级缓存**，同一进程内第二次读会命中旧值。
    # 真实环境里每个 HTTP 请求是独立进程，不会有这个问题；
    # 测试里必须显式失效，否则测的是缓存而不是逻辑。
    L.execute('_G.__exec["/usr/bin/dnschain-health status 2>/dev/null"] = ""')
    L.execute("package.loaded['luci.model.cbi.dnschain.dnschain'].invalidate()")
    L.execute("_G.__opts = {}")
    L.execute("__chunk3 = function()\n" + src + "\nend")
    L.eval("__chunk3()")
    empty_text = str(L.eval("__collect_text()"))
    # v0.21.0：静态分流图没有「无探测数据」这个状态 ——
    # 空数据时仍画出两档（各 0 个），所以只断言图还在。
    check_contains("无数据时图仍在", empty_text, "DNS 分流去向导图")

    # explain 路径：带 dc_explain 参数
    L.execute('_G.__formvalue = { dc_explain = "github.com" }')
    L.execute(r"""
_G.__exec["/usr/bin/dnschain-selftest explain 'github.com' 2>/dev/null"] =
	"DOMAIN=github.com\nCLASS=db-foreign\nPREFERRED=foreign\nACTIVE=foreign\n" ..
	"WATCH=0\nCUSTOM=0\nPROBE_DOMESTIC=OK\nPROBE_FOREIGN=OK\n" ..
	"ANSWER_DOMESTIC=1.2.3.4\nANSWER_FOREIGN=5.6.7.8\n" ..
	"DECISION=keep-foreign\nREASON=按归属走代理\n"
""")
    L.execute("_G.__opts = {}")
    L.execute("__chunk4 = function()\n" + src + "\nend")
    L.eval("__chunk4()")
    exp_text = str(L.eval("__collect_text()"))
    check_contains("解释结果含归属", exp_text, "数据库")
    check_contains("解释结果含探测", exp_text, "OK")
    check_contains("解释结果含答案对比", exp_text, "1.2.3.4")

    # 非法域名走 reject 分支
    L.execute('_G.__formvalue = { dc_explain = "not a domain" }')
    L.execute(r"""
_G.__exec["/usr/bin/dnschain-selftest explain 'not a domain' 2>/dev/null"] =
	"DOMAIN=not a domain\nCLASS=invalid\nDECISION=reject\nREASON=域名格式不合法\n"
""")
    L.execute("_G.__opts = {}")
    L.execute("__chunk5 = function()\n" + src + "\nend")
    L.eval("__chunk5()")
    rej_text = str(L.eval("__collect_text()"))
    check_contains("非法域名显示拒绝", rej_text, "拒绝")

    # explain 取不到结果时不能崩
    L.execute('_G.__formvalue = { dc_explain = "zzz.test" }')
    L.execute("_G.__opts = {}")
    L.execute("__chunk6 = function()\n" + src + "\nend")
    L.eval("__chunk6()")
    none_text = str(L.eval("__collect_text()"))
    check_contains("取不到解释时给告警", none_text, "取不到解释结果")


def test_module_translate_import():
    """被 require 的模块文件不得依赖全局 translate。

    为什么单独测这一条（v0.13.0 路由器实测踩过）：
      `general.lua` 是 CBI 模型，dispatcher 会在请求上下文里注入全局
      translate —— 它直接用裸 translate 是对的。
      但 `diagrams.lua` 是被 general.lua `require` 进来的**普通模块**，
      那里没有注入，必须自己 `require "luci.i18n"`。
      写裸 translate 会抛 `attempt to call global 'translate' (a nil value)`，
      而错误发生在 cfgvalue() 期间 → **整页 500**。

      本地测试曾经预先注入全局 translate 桩，于是本地全绿、路由器 500。
      这条断言就是防止那种「测试比真实环境宽松」的漂移。
    """
    print("=== 模块文件的 translate 引入 ===")

    base = os.path.join(REPO, "package/luci-app-dnschain/luasrc/model/cbi/dnschain")

    # diagrams.lua 是纯模块，必须显式引入
    p = os.path.join(base, "diagrams.lua")
    with open(p, encoding="utf-8") as f:
        src = f.read()

    body = "\n".join(
        line for line in src.splitlines() if not line.lstrip().startswith("--")
    )

    check_contains("diagrams.lua 显式 require luci.i18n",
                   body, 'require "luci.i18n"')

    # 有 translate 调用，但必须是通过 local 引入的
    n_calls = body.count("translate(")
    if n_calls > 0:
        ok("diagrams.lua 使用了 translate（%d 处）" % n_calls)
    else:
        bad("diagrams.lua 未使用 translate")

    check_contains("diagrams.lua 用 local translate 绑定",
                   body, "local translate = i18n.translate")

    # 反向：不得出现「没引入就调用」的情况 —— 若没有 local 绑定却调用了
    # translate，就是裸全局调用
    if "local translate" not in body and "translate(" in body:
        bad("diagrams.lua 裸调 translate（路由器上会 500）")
    else:
        ok("diagrams.lua 无裸调 translate")

    # dnschain.lua 不该用 translate（它是纯数据层）
    p2 = os.path.join(base, "dnschain.lua")
    with open(p2, encoding="utf-8") as f:
        src2 = f.read()
    body2 = "\n".join(
        line for line in src2.splitlines() if not line.lstrip().startswith("--")
    )
    if "translate(" in body2:
        bad("dnschain.lua 使用了 translate（数据层不该有 UI 文案）")
    else:
        ok("dnschain.lua 不含 translate（纯数据层）")

    # general.lua 是 CBI 模型，用裸 translate 是正常的
    p3 = os.path.join(base, "general.lua")
    with open(p3, encoding="utf-8") as f:
        src3 = f.read()
    check_contains("general.lua 使用 translate（CBI 模型靠全局注入）",
                   src3, "translate(")



def strip_lua_comments(src):
    """剥掉 Lua 的 -- 行注释与 --[[ ]] 块注释。

    ⚠️ 断言必须基于**真实代码**而非注释（AGENTS §6 第 6 条）。
    本仓库多次因为「解释错误写法的注释」让断言永久误报。
    """
    out = []
    in_block = False
    for line in src.splitlines():
        if in_block:
            if "]]" in line:
                in_block = False
            continue
        st = line.lstrip()
        if st.startswith("--[["):
            if "]]" not in line:
                in_block = True
            continue
        if st.startswith("--"):
            continue
        out.append(line)
    return "\n".join(out)


def test_v0144_fixes():
    """v0.14.4：Lua 层深审修复的回归断言。

    这些断言锁住「已经踩过的坑」，防止后续改动回退。
    """
    base = os.path.join(REPO, "package/luci-app-dnschain/luasrc")

    with open(os.path.join(base, "model/cbi/dnschain/dnschain.lua"),
              encoding="utf-8") as f:
        d = f.read()
    with open(os.path.join(base, "model/cbi/dnschain/diagrams.lua"),
              encoding="utf-8") as f:
        dg = f.read()
    with open(os.path.join(base, "model/cbi/dnschain/general.lua"),
              encoding="utf-8") as f:
        g = f.read()
    with open(os.path.join(base, "controller/dnschain.lua"),
              encoding="utf-8") as f:
        ctl = f.read()

    # ── S1：selftest 名称切分不能再用 [^—] ──
    #    Lua 字符类按字节工作，[^—] 会排除 E2/80/94 三个字节，
    #    导致含「一/上/下」等字的名称解析失败（实测 7/20 失败）。
    if "split_selftest_name" in d:
        ok("selftest 名称用字节安全的 split_selftest_name")
    else:
        bad("selftest 名称切分", "未找到 split_selftest_name")
    d_code = strip_lua_comments(d)
    dg_code = strip_lua_comments(dg)
    g_code = strip_lua_comments(g)

    if '[^—]' in d_code:
        bad("selftest 名称切分不再用 [^—]", "仍有 [^—] 字节类")
    else:
        ok("selftest 名称切分不再用 [^—]（字节类陷阱）")

    # ── S2：IPv6 端口解析 ──
    if 'hostport:match("^%[")' in d:
        ok("upstream_port 单独处理方括号 IPv6")
    else:
        bad("upstream_port 单独处理方括号 IPv6", "缺 ^%[ 判断")

    # ── S3：未知 state 归入 unknown ──
    if "normalize_state" in dg:
        ok("status_map 用 normalize_state 归一未知状态")
    else:
        bad("status_map 归一未知状态", "未找到 normalize_state")
    if 'r.state or "unknown"' in dg_code:
        bad("status_map 不再只兜 nil", "仍有 r.state or \"unknown\"")
    else:
        ok("status_map 不只兜 nil（空串/未知值也归 unknown）")

    # ── S4：status_layout 与 status_map 共用 layout_plan ──
    if "local function layout_plan" in dg and "layout_plan(rows)" in dg:
        ok("status_layout 与 status_map 共用 layout_plan")
    else:
        bad("status_layout 共用 layout_plan", "未找到 layout_plan 抽取")
    if "for _ in pairs(rows) do present" in dg_code:
        bad("status_layout 不再按行数算档位", "仍有 pairs(rows) 计数")
    else:
        ok("status_layout 不按行数算档位（改按档位数）")

    # ── S5：分流条数用 split_server_lines ──
    if "split_server_lines" in d:
        ok("list_stats 提供 split_server_lines（真正的 server= 条数）")
    else:
        bad("list_stats 提供 split_server_lines", "未找到")
    if "split_rule_count" in d_code:
        bad("死函数 split_rule_count 已删除", "仍有定义")
    else:
        ok("死函数 split_rule_count 已删除")

    # ── S6：apply 输出全出口解析 ──
    if "apply_message" in g:
        ok("apply 结果用 apply_message 统一解析")
    else:
        bad("apply 结果统一解析", "未找到 apply_message")
    # v0.21.0：apply 的输出契约变了（DNSMASQ=<state> → OK=/ERROR=），
    # 断言随之改为验这两个键，以及失败出口仍然优先判。
    for key, desc in [("OK=", "成功出口 OK="), ("ERROR=", "失败出口 ERROR=")]:
        if key in g:
            ok("apply_message 覆盖 %s" % desc)
        else:
            bad("apply_message 覆盖 %s" % desc, "缺 %s" % key)
    # 失败必须优先判（v0.14.4 S6：ERROR 时不能显示 ✓）
    if 'local err = out:match("ERROR=' in g:
        ok("apply_message 失败出口优先于成功")
    else:
        bad("apply_message 失败出口优先", "未先判 ERROR=")

    # ── M1：页面校验与 shell 对齐 ──
    for marker, name in [
        ("253", "总长 ≤253"),
        ("63", "每段 ≤63"),
        ("每段首尾不能是连字符", "label 首尾非连字符"),
        ("xn%-%-", "TLD 支持 xn--"),
    ]:
        if marker in g:
            ok("validate_domain 覆盖 %s" % name)
        else:
            bad("validate_domain 覆盖 %s" % name, "缺该判据")

    # ── M5：v0.21.0 health_summary 已删除，改为反向断言 ──
    if "function M.health_summary" in d:
        bad("health_summary 已删除", "仍有定义")
    else:
        ok("health_summary 已删除（原 M5 下划线解析断言随之失效）")

    # ── M6：reconcile 结果不再恒 true ──
    if "local function exec_ok" in d:
        ok("reconcile/import 结果用 exec_ok 判定")
    else:
        bad("reconcile 结果判定", "未找到 exec_ok")

    # ── M7：长域名截断（v0.15.1 改为按列宽截断）──
    #
    # 原断言查的是 `text_w(keep, 11) + ell_w > avail`（按整行可用宽度截）。
    # v0.15.1 把域名清单改成多列网格后，截断基准从「整行宽度」变成
    # 「单列宽度 col_w」，变量名也随之变化。
    #
    # 断言改为查**截断逻辑本身**（按字符回退直到放得下 + 补省略号），
    # 不绑定具体变量名 —— 否则每次调整布局都要改断言，
    # 而改断言时最容易顺手删掉（那就等于没有断言）。
    if "text_w(keep, 11) + ell_w > col_w" in dg:
        ok("超长域名按列宽硬切并补省略号")
    elif "text_w(keep, 11) + ell_w > avail" in dg:
        ok("超长域名按可用宽度硬切并补省略号")
    else:
        bad("超长域名硬切", "未找到截断逻辑")

    # 域名清单必须是多列网格（v0.15.1 修「显示不足」）
    if "n_cols" in dg and "COL_GAP" in dg:
        ok("域名清单用多列网格铺开（不再用「、」串接）")
    else:
        bad("域名清单未改为多列网格", "仍是旧的「、」串接折行")

    # 画布必须容得下最长的常见域名（v0.15.1：760 → 900）
    if "local STATUS_W = 900" in dg:
        ok("状态图画布宽 900（容得下长域名清单）")
    else:
        bad("状态图画布宽不是 900", "长域名会被迫截断")

    # ── M8：filter_aaaa 同步检查结果 ──
    if 'code = "uci_write_failed"' in d:
        ok("sync_dnsmasq_filter_aaaa 返回结构化错误")
    else:
        bad("sync_dnsmasq_filter_aaaa 检查结果", "仍无条件 return true")
    if 'code = "verify_failed"' in d:
        ok("filter_aaaa 写后读回校验")
    else:
        bad("filter_aaaa 写后读回校验", "未找到 verify_failed")

    # ── L1：判色不再回读译文 ──
    if 'tone = "bad"' in g_code and 'concl:find("未监听")' not in g_code:
        ok("链路结论按语义分支判色（不回读译文）")
    else:
        bad("链路结论按语义判色", "仍按中文子串判色")

    # ── L2：selftest 表格转义 ──
    if "dg.esc(it.name" in g and "dg.esc(it.detail" in g:
        ok("selftest 表格 name/detail 已转义")
    else:
        bad("selftest 表格转义", "未套 dg.esc")

    # ── L3：v0.21.0 起「最近探测时间」列随改道明细一起删除 ──
    if "r.last" in g:
        bad("改道明细的 r.last 已删除", "仍在渲染 r.last")
    else:
        ok("改道明细的 r.last 已删除")

    # ── L4：STATUS_H 死常量已删 ──
    if "STATUS_H" in dg_code:
        bad("STATUS_H 死常量已删", "仍有 STATUS_H")
    else:
        ok("STATUS_H 死常量已删")

    # ── L5：uptime 假实现已删 ──
    if "itrealvalue" in d:
        ok("注释说明为何不再解析 starttime")
    if "local pid, uptime" in d_code:
        bad("uptime 死变量已删", "仍有 local pid, uptime")
    else:
        ok("uptime 死变量已删")

    # ── L6：check_domains 死函数已删 ──
    if "function M.check_domains" in d_code:
        bad("check_domains 死函数已删", "仍有定义")
    else:
        ok("check_domains 死函数已删")

    # ── L7：16 项 → 20 项 ──
    if "16 项检查" in g_code:
        bad("检查项数文案已更新", "仍有「16 项检查」")
    else:
        ok("检查项数文案已更新（16 → 20）")

    # ── L9：controller 显式 require nixio.fs ──
    if 'require "nixio.fs"' in ctl:
        ok("controller 显式 require nixio.fs")
    else:
        bad("controller 显式 require nixio.fs", "仍依赖全局 nixio")

def main():
    syntax_check()
    test_controller()
    test_model()
    test_general()
    test_module_translate_import()
    test_v0144_fixes()

    print("")
    print("PASS=%d FAIL=%d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
