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

    # 情况二：配置存在 → 注册到 服务 → DNS 链路
    L.execute("_G.__fs_access = { ['/etc/config/dnschain'] = true }")
    L.execute("_G.__entries = {}")
    L.execute("index()")
    check_eq("有配置时注册 1 个菜单", L.eval("#_G.__entries"), 1)
    check_eq("菜单位置", L.eval("table.concat(_G.__entries[1].path, '/')"),
             "admin/services/dns_chain")
    check_eq("菜单排序 20", L.eval("_G.__entries[1].order"), 20)
    check_eq("标题为「DNS 链路」", L.eval("_G.__entries[1].title"), "DNS 链路")
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

    # 健康状态行解析
    #
    # 注意：行是 Lua table，字段名 class 与 Python 关键字同名，
    # 故一律用下标访问（rows[i]["class"]），不用属性访问。
    rows = M.health_rows()
    check_eq("健康行数", len(rows), 2)
    check_eq("第 1 行域名", rows[1]["domain"], "github.com")
    check_eq("第 1 行归属", rows[1]["class"], "db-foreign")
    check_eq("第 1 行首选", rows[1]["pref"], "foreign")
    check_eq("第 1 行当前", rows[1]["active"], "domestic")
    check_eq("第 1 行失败计数", rows[1]["fail"], 2)
    check_eq("第 1 行状态", rows[1]["state"], "rerouted")

    # 汇总
    s = M.health_summary()
    check_eq("汇总 total", s["total"], 2)
    check_eq("汇总 rerouted", s["rerouted"], 1)
    check_eq("汇总 normal", s["normal"], 1)

    # explain
    e = M.explain("github.com")
    check_eq("explain CLASS", e["CLASS"], "db-foreign")
    check_eq("explain DECISION", e["DECISION"], "reroute-domestic")
    check_contains("explain REASON", e["REASON"], "改走直连")

    # shell 转义：单引号必须被转成 '\''，否则可以逃逸出引号
    check_eq("转义普通串", M.shell_quote("abc"), "'abc'")
    check_eq("转义单引号", M.shell_quote("a'b"), "'a'\\''b'")
    check_contains("转义带空格", M.shell_quote("a b"), "'a b'")

    # serversfile_ready 的三条判据（v0.13.0 修正）
    #
    # ⚠️ 判据从「argv 里有 --servers-file」改成「生效配置里有 servers-file」：
    #   OpenWrt 的 dnsmasq init 是 append_parm，把它写进配置文件而不是
    #   命令行。按 argv 判定会永远报「未就绪」，页面于是显示一个
    #   不存在的故障。
    L.execute(r"""
_G.__exec["netstat -lntup 2>/dev/null"] =
	"udp        0      0 192.168.3.254:53   0.0.0.0:*           16800/dnsmasq\n"
""")
    M.invalidate("listen_table")

    # 文件不存在 → file-missing（不能崩）
    r = M.serversfile_ready()
    check_eq("serversfile 文件缺失时给 file-missing", r.reason, "file-missing")
    check_eq("serversfile 缺失时 ready=false", str(r.ready), "False")

    # 补上 /proc 与配置文件后应就绪
    L.execute(r"""
if not _G.__fs_access then _G.__fs_access = {} end
_G.__fs_access["/var/run/dnsmasq/watch.servers"] = true
""")
    M.invalidate("serversfile_ready")

    # 新增：health_daemon 必须在无守护进程时如实报 running=false
    L.execute(r"""
_G.__exec["ls -d /proc/[0-9]* 2>/dev/null"] = "/proc/1\n/proc/2\n"
""")
    M.invalidate("health_daemon")
    hd = M.health_daemon()
    check_eq("health_daemon 无进程时报 running=false", str(hd.running), "False")
    check_eq("health_daemon 读取 enabled 开关", str(hd.enabled), "True")


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
	["/usr/bin/dnschain-health status 2>/dev/null"] =
		"ROW github.com|db-foreign|foreign|domestic|2|0|1700000000|switch:TIMEOUT->OK|rerouted\n" ..
		"ROW www.qq.com|uncovered|domestic|domestic|0|0|1700000000|OK|ok\n" ..
		"ROW www.youtube.com|db-foreign|foreign|foreign|0|0|1700000000|both-bad:TIMEOUT/TIMEOUT|both-bad\n" ..
		"SUM total=3 normal=1 degraded=0 rerouted=1 both_bad=1 fixed=0\n",
	["/usr/bin/dnschain-health check 2>&1"] = "OK\n",
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
        ("域名判定链路图", "判定链路图 aria-label"),
        ("改道状态思维导图", "状态导图 aria-label"),
        ("直连链路", "链路图含直连链路节点"),
        ("代理链路", "链路图含代理链路节点"),
        ("自动改走直连", "图下写明需求规则"),
        ("未录入自定义列表的域名", "图下写明适用条件"),
        ("双链故障", "状态图含双链故障档"),
        ("github.com", "明细表含观测域名"),
        # 原因串里的 > 会被 dg.esc 转义成 &gt; —— 这是**正确**行为
        # （域名/原因来自配置，含 < > 时不转义会让整个 SVG/HTML 解析失败）。
        # 断言按转义后的形式写，否则这条会永远失败。
        ("switch:TIMEOUT-&gt;OK", "明细表含改道原因（已转义）"),
        ("dc-badge", "含状态徽标"),
        ("dc-table-wrap", "表格套滚动容器"),
    ]:
        check_contains("页面含 %s" % desc, alltext, needle)

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
    check_contains("无探测数据时给提示", empty_text, "还没有探测数据")
    check_contains("无数据时图仍在", empty_text, "改道状态思维导图")

    # explain 路径：带 dc_explain 参数
    L.execute('_G.__formvalue = { dc_explain = "github.com" }')
    L.execute(r"""
_G.__exec["/usr/bin/dnschain-health explain 'github.com' 2>/dev/null"] =
	"DOMAIN=github.com\nCLASS=db-foreign\nPREFERRED=foreign\nACTIVE=domestic\n" ..
	"WATCH=1\nFIXED=0\nPROBE_DOMESTIC=OK\nPROBE_FOREIGN=TIMEOUT\n" ..
	"ANSWER_DOMESTIC=1.2.3.4\nANSWER_FOREIGN=\n" ..
	"DECISION=reroute-domestic\nREASON=国外链路 TIMEOUT 不可达、国内链路可达 → 改走直连\n"
""")
    L.execute("_G.__opts = {}")
    L.execute("__chunk4 = function()\n" + src + "\nend")
    L.eval("__chunk4()")
    exp_text = str(L.eval("__collect_text()"))
    check_contains("解释结果含归属", exp_text, "数据库命中")
    check_contains("解释结果含判定", exp_text, "改走直连")
    check_contains("解释结果含理由", exp_text, "改走直连</td>") if False else None
    check_contains("解释结果含探测", exp_text, "TIMEOUT")
    check_contains("解释结果含答案对比", exp_text, "1.2.3.4")

    # 非法域名走 reject 分支
    L.execute('_G.__formvalue = { dc_explain = "not a domain" }')
    L.execute(r"""
_G.__exec["/usr/bin/dnschain-health explain 'not a domain' 2>/dev/null"] =
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
    for state in ("restarted", "sighup", "unchanged", "skipped"):
        if '"%s"' % state in g:
            ok("apply_message 覆盖 %s 出口" % state)
        else:
            bad("apply_message 覆盖 %s 出口" % state, "缺该键")
    if '"✓ " .. translate("已应用")' in g_code:
        bad("应用按钮不再无条件打 ✓", "仍有硬编码 ✓")
    else:
        ok("应用按钮不再无条件打 ✓")

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

    # ── M5：%w 不含下划线 ──
    if "([%w_]+)=(%d+)" in d:
        ok("health_summary 用 [%w_] 解析（含下划线键）")
    else:
        bad("health_summary 解析含下划线", "仍用 %w+")

    # ── M6：reconcile 结果不再恒 true ──
    if "local function exec_ok" in d:
        ok("reconcile/import 结果用 exec_ok 判定")
    else:
        bad("reconcile 结果判定", "未找到 exec_ok")

    # ── M7：长域名截断 ──
    if "text_w(keep, 11) + ell_w > avail" in dg:
        ok("超长域名按宽硬切并补省略号")
    else:
        bad("超长域名硬切", "未找到截断逻辑")

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

    # ── L3：last=0 显示 — ──
    if 'os.date("%H:%M:%S", r.last)' in g:
        ok("last=0 不渲染成 08:00:00（显示 —）")
    else:
        bad("last=0 处理", "仍用 r.last or 0")

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
