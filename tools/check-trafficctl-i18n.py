#!/usr/bin/env python3
"""校验 trafficctl 的中文翻译覆盖率。

用途：确认 status.js / portfw.js 里所有 _('…') 待翻译串都在 po/zh-cn 中有
非空译文。上游每次发版都会新增字符串，漏译在界面上表现为英文原文。

用法（仓库根目录）：
    python3 tools/check-trafficctl-i18n.py
    python3 tools/check-trafficctl-i18n.py --write-pot   # 顺带重生成 .pot 模板

退出码 0 = 中文译文全部覆盖；1 = po 有缺失或空译文（CI 可据此失败）。
.pot 缺失只提示、不致失败 —— 它仅是给译者的模板，不参与固件编译。
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / 'package' / 'luci-app-trafficctl'
JS_FILES = [
    PKG / 'htdocs/luci-static/resources/view/trafficctl/status.js',
    PKG / 'htdocs/luci-static/resources/view/trafficctl/portfw.js',
]
PO = PKG / 'po/zh-cn/luci-app-trafficctl.po'
POT = PKG / 'po/templates/luci-app-trafficctl.pot'

_ESC = {'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}


def unescape(s):
    out = []
    i = 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            out.append(_ESC.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)


def escape(s):
    return (s.replace('\\', '\\\\').replace('"', '\\"')
             .replace('\n', '\\n').replace('\t', '\\t'))


def parse_po(path):
    """返回 {真实 msgid: 真实 msgstr}"""
    txt = re.sub(r'^#.*$', '', path.read_text(encoding='utf-8'), flags=re.M)
    out = {}
    for block in re.split(r'\n\s*\n', txt):
        m = re.search(r'(?m)^msgid\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        if not m:
            continue
        mid = unescape(''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))))
        if not mid:
            continue
        ms = re.search(r'(?m)^msgstr\s+((?:"(?:[^"\\]|\\.)*"\s*)+)', block)
        out[mid] = (unescape(''.join(re.findall(r'"((?:[^"\\]|\\.)*)"', ms.group(1))))
                    if ms else '')
    return out


def extract_ui_strings(src):
    """提取 _( … ) 的完整运行时字符串。

    规则：
      - `_('a' + 'b')` 这类纯字面量拼接合并成一条；
      - 拼接中夹了函数调用（如 + E('code',{}) +）时，每段字面量各是独立
        msgid（与 LuCI 的 lit/translate 行为一致），逐段输出；
      - 判据是「标识符后紧跟 (」——不允许中间有空格，否则
        `flag (Linux …)` 这种「单词 + 空格 + 括号」会被误判成函数调用。
    """
    out = set()
    for m in re.finditer(r"_\(\s*((?:[^()]|\([^()]*\))*)\)", src):
        inner = m.group(1)
        lits = re.findall(r"'((?:[^'\\]|\\.)*)'", inner)
        if not lits:
            continue
        if not re.search(r"[A-Za-z_$][\w$.]*\(", inner):
            out.add(''.join(unescape(l) for l in lits))
        else:
            for l in lits:
                v = unescape(l)
                if v.strip():
                    out.add(v)
    return out


def write_pot(ui_strings):
    """按当前源码重生成 .pot 模板（msgstr 全空，按字典序排列）。"""
    header = (
        'msgid ""\n'
        'msgstr "Content-Type: text/plain; charset=UTF-8"\n'
    )
    body = ''.join(f'\nmsgid "{escape(k)}"\nmsgstr ""\n'
                   for k in sorted(ui_strings))
    POT.write_text(header + body, encoding='utf-8', newline='\n')
    print(f'已重写 {POT.relative_to(ROOT)}：{len(ui_strings)} 条')


def main():
    write = '--write-pot' in sys.argv[1:]

    if not PO.exists():
        print(f'错误：缺少 {PO.relative_to(ROOT)}', file=sys.stderr)
        return 1

    ui = set()
    for f in JS_FILES:
        if not f.exists():
            print(f'跳过（不存在）：{f.relative_to(ROOT)}')
            continue
        ui |= extract_ui_strings(f.read_text(encoding='utf-8'))

    if write:
        write_pot(ui)

    po = parse_po(PO)
    pot = parse_po(POT) if POT.exists() else {}

    missing_po = sorted(k for k in ui if k not in po)
    empty_po = sorted(k for k, v in po.items() if not v)
    missing_pot = sorted(k for k in ui if k not in pot)

    print(f'界面字符串 {len(ui)} 条；po {len(po)} 条；pot {len(pot)} 条')
    print(f'po 缺失 {len(missing_po)}；po 空译文 {len(empty_po)}；pot 缺失 {len(missing_pot)}')

    for label, items in (('PO 缺失', missing_po), ('PO 空译文', empty_po)):
        if items:
            print(f'\n=== {label} ===')
            for k in items:
                print('  ' + json.dumps(k, ensure_ascii=False))

    if missing_pot and not write:
        print(f'\n提示：pot 模板缺 {len(missing_pot)} 条，'
              f'可执行 python3 tools/check-trafficctl-i18n.py --write-pot 重生成')

    if missing_po or empty_po:
        print('\n中文翻译不完整', file=sys.stderr)
        return 1
    print('\n中文翻译完整')
    return 0


if __name__ == '__main__':
    sys.exit(main())
