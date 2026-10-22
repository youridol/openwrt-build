#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 general.lua 提取 translate() 的字符串，与 PO 比对，报告缺失项。

只做「报告 + 追加」，不改写已有条目。

为什么需要它：LuCI 的 PO 不会自动同步，页面新增文案后若不同步，
中文界面会中英混排。本脚本用于提交前自检。

用法:
  python3 tools/extract-dnschain-i18n.py            # 只报告
  python3 tools/extract-dnschain-i18n.py --write    # 追加缺失条目
"""
import re
import sys
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LUA_FILES = [
    "package/luci-app-dnschain/luasrc/model/cbi/dnschain/general.lua",
    "package/luci-app-dnschain/luasrc/model/cbi/dnschain/dnschain.lua",
    # v0.13.0：两张思维导图的文案（图例、状态档位、底部说明）都在这里。
    # 漏掉它会让「域名」tab 的图内文字全部中英混排 ——
    # 图是 SVG，缺译不会报错，只会静默显示成源文。
    "package/luci-app-dnschain/luasrc/model/cbi/dnschain/diagrams.lua",
    "package/luci-app-dnschain/luasrc/controller/dnschain.lua",
]
PO = "package/luci-app-dnschain/po/zh-cn/luci-app-dnschain.po"


def extract_translate_strings(path):
    """提取 translate("...") 与 translate("..." .. "..." ) 的完整拼接结果。

    处理两种形式：
      translate("单行")
      translate("第一段" ..
                "第二段")
    """
    with open(path, encoding="utf-8") as f:
        src = f.read()

    out = []
    # 匹配 translate( 后面到配对右括号之前的内容
    for m in re.finditer(r'translate\(', src):
        i = m.end()
        depth = 1
        j = i
        while j < len(src) and depth > 0:
            c = src[j]
            if c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
            j += 1
        body = src[i:j - 1]

        # 取出 body 里所有双引号字符串，按顺序拼起来
        parts = re.findall(r'"((?:[^"\\]|\\.)*)"', body)
        if not parts:
            continue
        text = "".join(parts)
        if not text:
            continue
        out.append(text)
    return out


def load_po_msgids(path):
    with open(path, encoding="utf-8") as f:
        txt = f.read()
    # msgid 可能是多行续接
    ids = set()
    cur = None
    for line in txt.splitlines():
        if line.startswith('msgid "'):
            if cur is not None:
                ids.add(cur)
            cur = line[7:-1]
        elif line.startswith('msgstr "'):
            if cur is not None:
                ids.add(cur)
                cur = None
        elif line.startswith('"') and cur is not None:
            cur += line[1:-1]
    if cur is not None:
        ids.add(cur)
    return ids


def main():
    write = "--write" in sys.argv

    po_path = os.path.join(REPO, PO)
    known = load_po_msgids(po_path)

    all_strs = []
    for rel in LUA_FILES:
        p = os.path.join(REPO, rel)
        if os.path.exists(p):
            all_strs.extend(extract_translate_strings(p))

    # 只关心含中文的
    zh = []
    for s in all_strs:
        if re.search(r'[\u4e00-\u9fff]', s) and s not in known and s not in zh:
            zh.append(s)

    if not zh:
        print("OK  无缺失（%d 条中文文案已在 PO 中）" % len([s for s in all_strs if re.search(r'[\u4e00-\u9fff]', s)]))
        return 0

    print("缺失 %d 条：" % len(zh))
    for s in zh:
        print("  " + s[:90].replace("\n", " "))

    if write:
        with open(po_path, "a", encoding="utf-8") as f:
            for s in zh:
                # PO 转义：反斜杠与双引号
                esc = s.replace("\\", "\\\\").replace('"', '\\"')
                f.write('\nmsgid "%s"\nmsgstr "%s"\n' % (esc, esc))
        print("\n已追加到 %s" % PO)
        return 0

    print("\n用 --write 追加，或手工补齐后重跑")
    return 1


if __name__ == "__main__":
    sys.exit(main())
