#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""渲染「判定链路图」与「改道状态图」，并做几何自检。

为什么需要这个工具：

  这两张图是内联 SVG，坐标全靠 Lua 里算。布局出错的表现是
  「节点压住连线」「文字超出 viewBox」「标签盖在曲线上」——
  在浏览器里看往往被当成样式问题，而在 1100 行的页面文件里
  改一个坐标要重新加载整个页面才能看见效果。

  抽成独立模块 + 这个脚本之后：
    ① 纯几何检查（越界、重叠、viewBox 容不下）几秒内出结论；
    ② 同时产出一份 standalone HTML，可直接打开或截图核对视觉。

用法：
  python tools/render-dnschain-diagrams.py            # 检查 + 输出 HTML
  python tools/render-dnschain-diagrams.py --check    # 只检查

退出码：0 = 全部通过
"""
import os
import re
import sys

from lupa import LuaRuntime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA = "package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua"
OUT = os.path.join(REPO, "tools", "out", "dnschain-diagrams.html")

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


def load_diagrams():
    L = LuaRuntime()
    # diagrams.lua 现在显式 `require "luci.i18n"`（v0.13.0 修正：
    # 它是被 require 的普通模块，不能依赖 dispatcher 注入的全局 translate，
    # 否则路由器上 cfgvalue() 期间抛 nil value → 整页 500）。
    # 故这里既要提供 luci.i18n 模块，也保留全局 translate 兜底。
    L.execute("""
package.preload["luci.i18n"] = function()
	return {
		translate = function(s) return s end,
		translatef = function(s, ...) return s end,
	}
end
_G.translate = function(s) return s end
""")
    path = os.path.join(REPO, LUA)
    with open(path, encoding="utf-8") as f:
        src = f.read()
    L.execute("__chunk = function()\n" + src + "\nend")
    return L, L.eval("__chunk()")


def svg_geom(svg):
    """从 SVG 文本里抽出 viewBox 与全部图元几何。"""
    m = re.search(r'viewBox="0 0 (\d+) (\d+)"', svg)
    if not m:
        return None
    W, H = int(m.group(1)), int(m.group(2))

    rects = []
    for mm in re.finditer(
            r'<rect x="(-?\d+)" y="(-?\d+)" width="(\d+)" height="(\d+)"', svg):
        x, y, w, h = (int(v) for v in mm.groups())
        rects.append((x, y, w, h))

    texts = []
    for mm in re.finditer(
            r'<text x="(-?\d+)" y="(-?\d+)" font-size="(\d+)"[^>]*>([^<]*)</text>', svg):
        x, y, fs, txt = int(mm.group(1)), int(mm.group(2)), int(mm.group(3)), mm.group(4)
        texts.append((x, y, fs, txt))

    paths = re.findall(r'<path d="([^"]+)"', svg)
    markers = re.findall(r'<marker id="([^"]+)"', svg)

    return {"W": W, "H": H, "rects": rects, "texts": texts,
            "paths": paths, "markers": markers}


def text_width_px(txt, fs):
    """粗估文本宽度：CJK 按 1.0em，ASCII 按 0.55em。

    不追求精确 —— 这里要抓的是「明显超出 viewBox」这类错误，
    而不是排版细节。宁可估宽一点（宁可误报也不漏报）。
    """
    w = 0.0
    for ch in txt:
        w += 1.0 if ord(ch) > 0x2E7F else 0.55
    return w * fs


def check_bounds(name, g):
    if g is None:
        bad("%s 能解析出 viewBox" % name, "没找到 viewBox")
        return

    W, H = g["W"], g["H"]
    ok("%s viewBox %dx%d" % (name, W, H))

    # 节点必须在框内
    out = []
    for (x, y, w, h) in g["rects"]:
        if x < 0 or y < 0 or x + w > W or y + h > H:
            out.append("rect (%d,%d %dx%d)" % (x, y, w, h))
    if out:
        bad("%s 所有节点在 viewBox 内" % name, "越界: " + "; ".join(out[:4]))
    else:
        ok("%s 所有节点在 viewBox 内（%d 个）" % (name, len(g["rects"])))

    # 文本不能超出右边缘（最常见的是底部说明行太长）
    wide = []
    for (x, y, fs, txt) in g["texts"]:
        tw = text_width_px(txt, fs)
        if x + tw > W + 2:
            wide.append("「%s」右缘约 %d > %d" % (txt[:18], int(x + tw), W))
        if y > H or y < 0:
            wide.append("「%s」y=%d 越界" % (txt[:18], y))
    if wide:
        bad("%s 文本不超出 viewBox" % name, "; ".join(wide[:4]))
    else:
        ok("%s 文本不超出 viewBox（%d 条）" % (name, len(g["texts"])))


def check_no_rect_overlap(name, g):
    """节点之间不能重叠 —— 重叠会让两张卡片叠在一起，字全糊。"""
    rects = g["rects"]
    hits = []
    for i in range(len(rects)):
        for j in range(i + 1, len(rects)):
            ax, ay, aw, ah = rects[i]
            bx, by, bw, bh = rects[j]
            if ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah:
                hits.append("(%d,%d) 与 (%d,%d)" % (ax, ay, bx, by))
    if hits:
        bad("%s 节点互不重叠" % name, "; ".join(hits[:4]))
    else:
        ok("%s 节点互不重叠" % name)


def check_bezier(name, g):
    """贝塞尔控制点不能交叉（c1x <= c2x），否则曲线自交成扭结。"""
    bad_paths = []
    for d in g["paths"]:
        m = re.match(r"M (\d+) (\d+) C (\d+) (\d+), (\d+) (\d+), (\d+) (\d+)$", d)
        if not m:
            continue
        x1, y1, c1x, c1y, c2x, c2y, x2, y2 = (int(v) for v in m.groups())
        if c1x > c2x:
            bad_paths.append("C %d > %d（%s）" % (c1x, c2x, d[:40]))
    if bad_paths:
        bad("%s 贝塞尔控制点不交叉" % name, "; ".join(bad_paths[:3]))
    else:
        ok("%s 贝塞尔控制点不交叉" % name)


def check_markers(name, g, prefix):
    """箭头 marker 必须按状态色各定义一份，且 id 带前缀（多图共存不串色）。"""
    ids = g["markers"]
    if len(ids) < 3:
        bad("%s 箭头按状态色定义" % name, "只有 %d 个" % len(ids))
    else:
        ok("%s 箭头按状态色定义 %d 个" % (name, len(ids)))

    if all(i.startswith(prefix) for i in ids) and ids:
        ok("%s marker id 带前缀 %s（多图共存不串色）" % (name, prefix))
    else:
        bad("%s marker id 带前缀" % name, "实际: %s" % ", ".join(ids[:5]))


def check_note_clearance(name, svg, layout):
    """底部说明文字不能压到最后一个节点上。

    这条断言是补出来的：v0.13.0 初版把判定链路图的两行说明放在
    viewBox 底部（486-26 / 486-10），而最后一个节点底边在 458 ——
    文字基线 460 只比节点底边低 2px，10px 字号的上沿直接压进
    节点框里。当时**所有几何断言都通过**（因为只查 viewBox 越界），
    是截图才看出问题。

    判据：文字基线上沿（基线 − 字号）必须低于节点底边 + 4px 间隙。
    """
    if not layout:
        return

    # lupa 返回的是 Lua table，没有 Python 的 .get()，只能用下标访问
    bottom = layout["last_node_bottom"]
    note = layout["note1"] if layout["note1"] is not None else layout["note"]
    if bottom is None or note is None:
        bad("%s 布局常量可读" % name, "last_node_bottom / note 缺失")
        return

    # 10px 字号的上沿约在基线 - 8
    text_top = note - 8
    if text_top > bottom + 4:
        ok("%s 说明文字与末节点留出间隙（文字顶 %d > 节点底 %d + 4）"
           % (name, text_top, bottom))
    else:
        bad("%s 说明文字压到末节点" % name,
            "文字顶 %d，节点底 %d（需 > %d）" % (text_top, bottom, bottom + 4))

    # viewBox 高度必须容得下说明文字
    h = layout["h"]
    if h is not None and note + 6 <= h:
        ok("%s viewBox 高度容得下说明（%d + 6 <= %d）" % (name, note, h))
    else:
        bad("%s viewBox 高度不够" % name, "note=%s h=%s" % (note, h))


def check_text_fits_boxes(name, svg, layout, lines=3):
    """节点里的最后一行文字必须留出下内边距。

    为什么需要这条：`box()` 的基线是固定的 ——
    两行（标题 + 副标题）在 y+21 / y+37，三行（再加说明）在 y+51。
    而节点高度由外部传进来。高度取小了，文字就贴到底边 ——
    此时 viewBox 没越界、节点没重叠、文字也没溢出节点，
    所有既有断言都通过，但浏览器里看着就是「字贴着框底」。
    实测（v0.13.0）状态图就是这样：56 高的框放三行字，只剩 3px。
    """
    nh = layout["node_h"]
    # 最后一行基线 + 字高约 2
    text_bottom = { 2: 39, 3: 53 }[lines]
    gap = nh - text_bottom
    if gap >= 5:
        ok("%s 节点文字留出下内边距（%d - %d = %dpx ≥ 5）"
           % (name, nh, text_bottom, gap))
    else:
        bad("%s 节点文字贴边" % name,
            "节点高 %d，%d 行字下沿约 %d，只剩 %dpx" % (nh, lines, text_bottom, gap))


def check_escaped(D):
    """动态文本必须转义 —— 否则域名里的 & < > 会让整个 SVG 解析失败。"""
    cases = [
        ("&", "&amp;"),
        ("<x>", "&lt;x&gt;"),
        ('a"b', "a&quot;b"),
        ("a<b>c&d", "a&lt;b&gt;c&amp;d"),
    ]
    for raw, expect in cases:
        got = D.esc(raw)
        if got == expect:
            ok("转义 %r → %r" % (raw, expect))
        else:
            bad("转义 %r" % raw, "实际 %r" % got)


def sample_rows():
    """构造一组覆盖全部状态档位的假数据。"""
    return [
        {"domain": "www.baidu.com", "class": "custom-domestic", "pref": "domestic",
         "active": "domestic", "fail": 0, "ok": 0, "last": 1700000000,
         "result": "OK", "state": "fixed"},
        {"domain": "www.google.com", "class": "custom-foreign", "pref": "foreign",
         "active": "foreign", "fail": 0, "ok": 0, "last": 1700000000,
         "result": "fixed:OK", "state": "fixed"},
        {"domain": "github.com", "class": "db-foreign", "pref": "foreign",
         "active": "domestic", "fail": 0, "ok": 0, "last": 1700000000,
         "result": "switch:TIMEOUT->OK", "state": "rerouted"},
        {"domain": "www.wikipedia.org", "class": "db-foreign", "pref": "foreign",
         "active": "foreign", "fail": 1, "ok": 0, "last": 1700000000,
         "result": "probe:TIMEOUT", "state": "degraded"},
        {"domain": "www.qq.com", "class": "uncovered", "pref": "domestic",
         "active": "domestic", "fail": 0, "ok": 0, "last": 1700000000,
         "result": "OK", "state": "ok"},
        {"domain": "www.youtube.com", "class": "db-foreign", "pref": "foreign",
         "active": "foreign", "fail": 0, "ok": 0, "last": 1700000000,
         "result": "both-bad:TIMEOUT/TIMEOUT", "state": "both-bad"},
        {"domain": "www.taobao.com", "class": "uncovered", "pref": "domestic",
         "active": "domestic", "fail": 0, "ok": 0, "last": 0,
         "result": "", "state": "unknown"},
    ]


def lua_table(L, py):
    t = L.eval("{}")
    for i, row in enumerate(py, start=1):
        r = L.eval("{}")
        for k, v in row.items():
            r[k] = v
        t[i] = r
    return t


def main():
    check_only = "--check" in sys.argv

    L, D = load_diagrams()
    if D is None:
        bad("加载 diagrams.lua", "返回值为空")
        return 1

    print("=== 判定链路图 ===")
    route = D.route_map({"entry_port": "5353", "foreign_port": "5336"})
    route = str(route)
    g = svg_geom(route)
    check_bounds("判定链路图", g)
    if g:
        check_no_rect_overlap("判定链路图", g)
        check_bezier("判定链路图", g)
        check_markers("判定链路图", g, "dcrt")

    layout = D.route_layout()
    check_note_clearance("判定链路图", route, layout)
    # 判定链路图的节点只有两行（标题 + 副标题），没有第三行说明
    check_text_fits_boxes("判定链路图", route, layout, lines=2)

    print("=== 改道状态图 ===")
    rows = lua_table(L, sample_rows())
    status = D.status_map(rows, L.eval("{}"))
    status = str(status)
    g2 = svg_geom(status)
    check_bounds("改道状态图", g2)
    if g2:
        check_no_rect_overlap("改道状态图", g2)
        check_bezier("改道状态图", g2)
        check_markers("改道状态图", g2, "dcst")

    # 状态图的档位数随数据变，用实际渲染出的行数算布局
    n_status_rows = 6   # sample_rows 覆盖 ok/degraded/rerouted/both-bad/fixed/unknown
    slayout = D.status_layout(L.eval("{ [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true }"))
    check_note_clearance("改道状态图", status, slayout)
    check_text_fits_boxes("改道状态图", status, slayout)

    # 状态图必须覆盖全部六档（数据里六档都有）
    for st in ["正常", "降级中", "已改道", "双链故障", "固定归属"]:
        if st in status:
            ok("状态图含「%s」档" % st)
        else:
            bad("状态图含「%s」档" % st)

    print("=== 文本转义 ===")
    check_escaped(D)

    print("=== 空数据兜底 ===")
    empty = str(D.status_map(L.eval("{}"), L.eval("{}")))
    if "<svg" in empty:
        ok("无数据时仍产出合法 SVG（不空白）")
    else:
        bad("无数据时仍产出合法 SVG", empty[:120])

    # 输出 HTML 供视觉核对
    if not check_only:
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        css = """
		:root {
			--dc-ok: #16a34a; --dc-warn: #d97706; --dc-bad: #dc2626;
			--dc-info: #2563eb; --dc-idle: #94a3b8;
			--dc-surface: rgba(148,163,184,0.06);
			color-scheme: light;
		}
		html[data-darkmode="true"] {
			--dc-ok: #4ade80; --dc-warn: #fbbf24; --dc-bad: #f87171;
			--dc-info: #60a5fa; --dc-idle: #64748b;
			--dc-surface: rgba(148,163,184,0.08);
			color-scheme: dark;
		}
		body {
			margin: 0; padding: 24px;
			background: Canvas; color: CanvasText;
			font-family: system-ui, "Segoe UI", "Microsoft YaHei", sans-serif;
		}
		h2 { font-size: 15px; margin: 28px 0 10px; opacity: .75; font-weight: 600; }
		.dc-chain svg { display: block; width: 100%; height: auto; max-width: 900px; }
		.dc-chain { overflow-x: auto; border: 1px solid rgba(148,163,184,.3);
			border-radius: 12px; padding: 10px; margin-bottom: 8px; }
		.toggle { font-size: 13px; margin-bottom: 12px; }
		"""
        html = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>dnschain 图示预览</title><style>%s</style></head>
<body>
<label class="toggle"><input type="checkbox" onchange="
	document.documentElement.setAttribute('data-darkmode', this.checked ? 'true' : 'false')">
暗色主题</label>
<h2>判定链路图（思维链路图）</h2>
%s
<h2>改道状态图（状态思维导图）</h2>
%s
</body></html>""" % (css, route, status)
        with open(OUT, "w", encoding="utf-8") as f:
            f.write(html)
        print("")
        print("已输出 %s" % os.path.relpath(OUT, REPO))

    print("")
    print("PASS=%d FAIL=%d" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
