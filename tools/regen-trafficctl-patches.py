#!/usr/bin/env python3
"""从上游基线重新导出 patches/luci-app-trafficctl/*.patch。

这是 tools/sync-trafficctl.sh 的本地等价物：不联网、不覆盖包目录，
只按给定的上游基线目录重算差异 patch。用于「已 vendor 好包里改了东西，
只想让 patch 跟上」的场景。

用法：
    # 指向上游 1.21.4 的包目录（子目录 luci-app-trafficctl/，可含 CRLF）
    python3 tools/regen-trafficctl-patches.py /path/to/upstream-repo

退出码 0 = 生成并校验通过；非 0 = 失败。
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PKG = ROOT / 'package' / 'luci-app-trafficctl'
PATCHDIR = ROOT / 'patches' / 'luci-app-trafficctl'

# patch 分组：每个 patch 负责一组文件，顺序即套用顺序
GROUPS = [
    ('0001-rewrite-bytes-nft-for-this-kernel.patch',
     'rewrite nft byte counter backend for this kernel',
     ['root/usr/local/bin/trafficctl-bytes-nft.sh']),
    ('0002-ui-tabs-default-refresh-and-layout.patch',
     'settings tabs, default refresh, card waterfall layout',
     ['htdocs/luci-static/resources/view/trafficctl/status.js',
      'htdocs/luci-static/resources/view/trafficctl/status.css',
      # refresh_interval 的路由端默认值：config 定义 + rpcd 读写
      'root/etc/config/trafficctl',
      'root/usr/libexec/rpcd/luci.trafficctl']),
    ('0003-add-zh-cn-translation.patch',
     'add zh-cn translation',
     ['po/zh-cn/luci-app-trafficctl.po',
      'po/templates/luci-app-trafficctl.pot']),
]


def run(cmd, cwd=None, check=True):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f'命令失败: {" ".join(map(str, cmd))}\n{r.stdout}\n{r.stderr}')
    return r


def to_lf(path: Path):
    for f in path.rglob('*'):
        if f.is_file():
            b = f.read_bytes()
            if b'\r\n' in b:
                f.write_bytes(b.replace(b'\r\n', b'\n'))


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    up = Path(sys.argv[1]).resolve()
    # 允许指向仓库根（取子目录）或直接指向包目录
    src = up / 'luci-app-trafficctl' if (up / 'luci-app-trafficctl').is_dir() else up
    if not src.is_dir():
        print(f'错误：找不到上游包目录 {src}', file=sys.stderr)
        return 1

    PATCHDIR.mkdir(parents=True, exist_ok=True)
    for old in PATCHDIR.glob('*.patch'):
        old.unlink()

    with tempfile.TemporaryDirectory() as td:
        # 说明：patch 的路径要能直接 `git apply -p1`（与 CI 里 dnsproxy 的
        # 用法一致），所以基线仓库的**根**就是包目录本身，不再套一层 pkg/，
        # 否则会生成 a/pkg/… 而需要 -p2。
        w = Path(td) / 'gen'
        w.mkdir(parents=True)
        shutil.copytree(src, w, dirs_exist_ok=True)
        to_lf(w)

        G = ['git', '-c', 'user.email=regen@local', '-c', 'user.name=regen',
             '-c', 'core.autocrlf=false']
        run([*G, 'init', '-q'], cwd=w)
        run([*G, 'add', '-A'], cwd=w)
        run([*G, 'commit', '-qm', 'upstream baseline'], cwd=w)
        print(f'基线文件数：{sum(1 for _ in w.rglob("*") if _.is_file() and ".git" not in _.parts)}')

        print('\n=== 生成 patch ===')
        for out, desc, files in GROUPS:
            for rel in files:
                s = PKG / rel
                if not s.is_file():
                    print(f'  警告：本地缺少 {rel}，该文件不会进入 patch')
                    continue
                d = w / rel
                d.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(s, d)
            run([*G, 'add', '-A'], cwd=w)
            diff = run([*G, 'diff', '--cached', '--binary'], cwd=w).stdout
            (PATCHDIR / out).write_text(diff, encoding='utf-8', newline='\n')
            run([*G, 'commit', '-qm', desc], cwd=w)
            print(f'  {out:<56} {len(diff.splitlines()):>5} 行')

        print('\n=== 验证：干净基线上重新套用 ===')
        v = Path(td) / 'verify'
        v.mkdir(parents=True)
        shutil.copytree(src, v, dirs_exist_ok=True)
        to_lf(v)
        run([*G, 'init', '-q'], cwd=v)
        run([*G, 'add', '-A'], cwd=v)
        run([*G, 'commit', '-qm', 'base'], cwd=v)

        for p in sorted(PATCHDIR.glob('*.patch')):
            chk = run([*G, 'apply', '--check', str(p)], cwd=v, check=False)
            if chk.returncode != 0:
                print(f'  FAIL {p.name}\n{chk.stderr}', file=sys.stderr)
                return 1
            run([*G, 'apply', str(p)], cwd=v)
            print(f'  OK   {p.name}')

        # 说明：本地可能比上游基线多出文件（如新增的 po/zh-cn、或 vendored
        # 时一并拷入的 LICENSE/README）。这些新增文件同样应进入相应 patch，
        # 故这里只提示「不属于任何 patch 分组」的文件，便于发现遗漏。
        grouped = {rel for _, _, files in GROUPS for rel in files}
        local_files = {str(f.relative_to(PKG)) for f in PKG.rglob('*') if f.is_file()}
        up_files = {str(f.relative_to(src)) for f in src.rglob('*') if f.is_file()}
        ungrouped = sorted(local_files - up_files - grouped - {'LICENSE', 'README.md'})
        if ungrouped:
            print(f'\n注意：以下文件本地有、上游基线没有，且未归入任何 patch 分组：'
                  f'{ungrouped}')
            print('      若它们是本地改动，请在 GROUPS 中登记，否则不会生成 patch。')

        ok = True
        for rel in {str(f.relative_to(v)) for f in v.rglob('*')
                    if f.is_file() and '.git' not in f.parts}:
            a = (v / rel).read_bytes()
            b = (PKG / rel).read_bytes()
            if a != b:
                print(f'  不一致：{rel}', file=sys.stderr)
                ok = False
        if not ok:
            return 1
        print('  一致')

    print('\n完成')
    return 0


if __name__ == '__main__':
    sys.exit(main())
