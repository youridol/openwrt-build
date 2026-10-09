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
import os
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
      # Telegram Bot 提升为页面级独立 tab（新增视图 + menu.d 登记 + 排序）
      'htdocs/luci-static/resources/view/trafficctl/telegram.js',
      'root/usr/share/luci/menu.d/luci-app-trafficctl.json',
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


def local_index_modes():
    """读本仓库 git 索引里的文件模式 {相对包路径: '100644'|'100755'}。

    为什么需要它：本脚本在临时目录里建 git 仓库来生成 patch，而 Windows 上
    文件系统会把所有文件报告为可执行 → `git add -A` 一律记成 100755，于是
    patch 里出现大量 `index a..b 100755` 这种**伪 mode 变更**，套用时会打印
    `has type 100644, expected 100755` 之类的告警，甚至把不该可执行的
    Makefile / *.js / config 改成可执行。

    权威模式来源是本仓库的 git 索引（已与上游 1.21.4 的索引核对一致：
    29 × 100755 + 11 × 100644）。
    """
    r = run(['git', '-c', 'core.autocrlf=false', 'ls-files', '-s', '--',
             'package/luci-app-trafficctl'], cwd=ROOT)
    modes = {}
    for line in r.stdout.splitlines():
        parts = line.split(None, 3)
        if len(parts) < 4:
            continue
        mode, _sha, _stage, path = parts
        rel = path.split('package/luci-app-trafficctl/', 1)[-1]
        modes[rel] = mode
    return modes


def apply_modes(repo, modes):
    """把临时仓库里的文件权限改成与给定模式表一致。

    为什么必须在 `git add` **之前**做：上游 clone 位于 Windows 挂载点
    （`/mnt/c/...`），DrvFs 把文件一律报告为 0777 可执行；`shutil.copytree`
    会保留该权限，于是 `git add -A` 把每个文件都记成 100755，patch 里随之
    出现大量伪 mode 变更，套用时报
    `warning: xxx has type 100755, expected 100644`。

    故这里直接 `os.chmod` 落盘权限，再让 git 去读；`git update-index --chmod`
    仅作为兜底（个别情况下索引缓存不刷新）。
    """
    fixed = 0
    for rel, mode in sorted(modes.items()):
        f = repo / rel
        if not f.is_file():
            continue
        want_exec = (mode == '100755')
        cur = os.stat(f).st_mode
        cur_exec = bool(cur & 0o111)
        if cur_exec != want_exec:
            new = (cur | 0o111) if want_exec else (cur & ~0o111)
            os.chmod(f, new & 0o7777)
            fixed += 1
    # 未登记的文件一律去执行位（新增文件如 po/zh-cn 应保持 100644）
    for f in repo.rglob('*'):
        if not f.is_file() or '.git' in f.parts:
            continue
        rel = str(f.relative_to(repo))
        if rel in modes:
            continue
        m = os.stat(f).st_mode
        if m & 0o111:
            os.chmod(f, m & ~0o111)
            fixed += 1
    if fixed:
        print(f'  已修正 {fixed} 个文件的执行位')


def stage_modes(repo, modes):
    """在 git add 之后把索引里的模式钉死（兜底 os.chmod 未覆盖的场景）。"""
    for rel, mode in sorted(modes.items()):
        if not (repo / rel).is_file():
            continue
        arg = '--chmod=+x' if mode == '100755' else '--chmod=-x'
        run(['git', '-c', 'core.autocrlf=false', 'update-index', arg, rel],
            cwd=repo, check=False)


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

    # 权威模式表（见 local_index_modes 的说明）
    MODES = local_index_modes()
    print(f'本地索引模式表：{len(MODES)} 条 '
          f'（100755={sum(1 for m in MODES.values() if m == "100755")}，'
          f'100644={sum(1 for m in MODES.values() if m == "100644")}）')

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
        # 必须在 git add 之前改权限：DrvFs 把 /mnt/c 下文件报成 0777，
        # copytree 会带过来，否则 git 一律记成 100755。
        apply_modes(w, MODES)
        run([*G, 'add', '-A'], cwd=w)
        stage_modes(w, MODES)
        run([*G, 'commit', '-qm', 'upstream baseline'], cwd=w)
        print(f'基线文件数：{sum(1 for _ in w.rglob("*") if _.is_file() and ".git" not in _.parts)}')
        # 基线必须干净（无 mode 变更），否则 patch 里会混入伪差异
        st = run([*G, 'status', '--porcelain'], cwd=w).stdout.strip()
        if st:
            print(f'  警告：基线工作树不干净，可能有 mode 漂移：\n{st}')

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
            # 拷贝进来的文件同样会被 DrvFs 报成 0777，逐个钉回目标模式
            # （新增文件不在 MODES 里，apply_modes 会统一去掉执行位）
            apply_modes(w, MODES)
            run([*G, 'add', '-A'], cwd=w)
            stage_modes(w, MODES)
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
        apply_modes(v, MODES)
        run([*G, 'add', '-A'], cwd=v)
        stage_modes(v, MODES)
        run([*G, 'commit', '-qm', 'base'], cwd=v)

        for p in sorted(PATCHDIR.glob('*.patch')):
            chk = run([*G, 'apply', '--check', str(p)], cwd=v, check=False)
            if chk.returncode != 0:
                print(f'  FAIL {p.name}\n{chk.stderr}', file=sys.stderr)
                return 1
            # 不使用 --check 的静默模式：把告警（如 mode 不符）也打出来
            r = run([*G, 'apply', str(p)], cwd=v, check=False)
            if r.returncode != 0:
                print(f'  FAIL(apply) {p.name}\n{r.stderr}', file=sys.stderr)
                return 1
            warn = (r.stderr or '').strip()
            print(f'  OK   {p.name}' + (f'  [{warn}]' if warn else ''))

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
