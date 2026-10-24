#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 GitHub Actions 工作流里所有 run: 块抽出来，交给真实 dash 做语法检查。

为什么需要这个（而不是只看 YAML 能不能解析）：
    YAML 合法 ≠ shell 合法。本仓库踩过的最贵的一类失败是
    「bash 专有语法写进 tools/*.sh，dash 解析期 exit 2」，
    表现为整条流水线一步未执行、编译全 skipped、没有任何产物。
    工作流里的 run: 块同样由 dash 执行（runner 的 /bin/sh 是 dash），
    而 PyYAML 解析通过完全不代表这些块能跑。

用法：
    python tools/verify-workflow-scripts.py [--dash <path>] [workflow ...]

默认检查 .github/workflows/*.yml。
退出码 0 = 全部通过；1 = 有语法错误。
"""

import argparse
import glob
import os
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.stderr.write("!!! 需要 PyYAML：python -m pip install pyyaml\n")
    sys.exit(2)


def iter_run_blocks(doc):
    """产出 (位置描述, 脚本正文)。"""
    jobs = doc.get("jobs") or {}
    for job_name, job in jobs.items():
        if not isinstance(job, dict):
            continue
        for idx, step in enumerate(job.get("steps") or []):
            if not isinstance(step, dict):
                continue
            script = step.get("run")
            if not script:
                continue
            label = "%s/steps[%d] %s" % (job_name, idx, step.get("name", "<unnamed>"))
            yield label, script


def check(path, dash):
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)

    # GitHub Actions 的 run 块默认以 bash -e 执行，但仓库约定 CI 的 /bin/sh
    # 是 dash，且 tools/*.sh 一律按 POSIX 写。用 `dash -n` 只做语法检查，
    # 不执行 —— 这些块里有 make、gh、apt-get，执行会真的动系统。
    failures = []
    total = 0
    for label, script in iter_run_blocks(doc):
        total += 1
        with tempfile.NamedTemporaryFile(
            "w", suffix=".sh", delete=False, encoding="utf-8", newline="\n"
        ) as tmp:
            tmp.write(script)
            tmp_path = tmp.name
        try:
            proc = subprocess.run(
                [dash, "-n", tmp_path], capture_output=True, text=True
            )
            if proc.returncode != 0:
                failures.append((label, proc.stderr.strip()))
        finally:
            os.unlink(tmp_path)

    print("%-46s run 块 %3d 个，语法错误 %d 个" % (os.path.basename(path), total, len(failures)))
    for label, err in failures:
        print("  FAIL %s" % label)
        for line in err.splitlines()[:6]:
            print("       %s" % line)
    return len(failures)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dash", default="dash")
    ap.add_argument("workflows", nargs="*")
    args = ap.parse_args()

    paths = args.workflows or sorted(glob.glob(".github/workflows/*.yml"))
    if not paths:
        sys.stderr.write("!!! 没找到任何工作流文件\n")
        return 2

    bad = 0
    for p in paths:
        bad += check(p, args.dash)

    if bad:
        print("\n!!! 共 %d 个 run 块无法被 dash 解析 —— CI 会在解析期直接失败" % bad)
        return 1
    print("\nOK   所有 run 块均通过 dash -n 语法检查")
    return 0


if __name__ == "__main__":
    sys.exit(main())
