#!/usr/bin/env python3
"""把 vendor/SOURCES.json 里的真实 sha256 回填进 versions/*.toml 的 FILL: 占位。

    python3 scripts/fill-placeholders.py <repo-root> <vendor-dir> [--scope 7.4.33,8.0.30]

两个设计点，都是被实际问题逼出来的：

1) 占位符自带文件名（`FILL:php-7.4.33.tar.gz`），不是按顺序填洞。G2/G3 只有 PHP
   源码一个输入，按位置填必然错位。

2) **门禁按版本作用域**。vendor.sh 支持 --versions 只拉一个版本（CI 每次也只建
   一个），但回填过去会扫描所有 toml：只要有一个别的版本还没轮到冻结，就直接
   SystemExit —— 结果单版本链路永远跑不过第一步。2026-11-08 L2 实测就死在这里：
   7.4.33 的源码已经下载校验完，却被 5.6.40 的未回填占位堵住，编译一步都没开始。
   现在的语义是：本轮的版本（--scope）必须全部冻结，否则硬失败；不在本轮范围的
   版本有多少占位都不拦，只做能填的先填、剩下的留到它自己的那一轮。

残留占位不清空文件名后缀引号是旧 bug：`re.findall(r"FILL:\\S+")` 会把结尾的 `"`
一起吃掉，报错信息里变成 `FILL:php-5.6.40.tar.gz"` —— 看着像 toml 写坏了。
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

# 只接受文件名安全字符，绝不吃掉 toml 的闭合引号。
PLACEHOLDER = re.compile(r"FILL:[A-Za-z0-9._+-]+")


def main() -> int:
    argv = sys.argv[1:]
    scope: set[str] = set()
    pos: list[str] = []
    i = 0
    while i < len(argv):
        if argv[i] == "--scope":
            if i + 1 >= len(argv):
                sys.exit("--scope needs a comma-separated value")
            scope = {v.strip() for v in argv[i + 1].split(",") if v.strip()}
            i += 2
            continue
        if argv[i].startswith("--"):
            sys.exit(f"unknown option {argv[i]}")
        pos.append(argv[i])
        i += 1
    if len(pos) != 2:
        sys.exit("usage: fill-placeholders.py <repo-root> <vendor-dir> [--scope a,b]")

    root, vendor = pathlib.Path(pos[0]), pathlib.Path(pos[1])
    ledger = vendor / "SOURCES.json"
    if not ledger.is_file():
        sys.exit(f"missing {ledger} — run vendor.sh first")
    src = json.loads(ledger.read_text())

    blocked: list[str] = []
    changed = 0
    for p in sorted((root / "versions").glob("*.toml")):
        original = p.read_text(encoding="utf-8")
        if "FILL:" not in original:
            continue
        text = original
        for name, meta in src.items():
            text = text.replace(f"FILL:{name}", meta["sha256"])
        left = sorted(set(PLACEHOLDER.findall(text)))
        in_scope = not scope or p.stem in scope

        if left and in_scope:
            blocked.append(f"{p.name}: {' '.join(left)}")
            continue

        if left:
            # 不在本轮范围：能填的先填，剩下的留给它自己那一轮。
            if text != original:
                p.write_text(text, encoding="utf-8", newline="\n")
                changed += 1
            print(
                f"partial {p.relative_to(root)} "
                f"({len(left)} placeholder(s) left, not in this run's scope)"
            )
            continue

        p.write_text(text, encoding="utf-8", newline="\n")
        changed += 1
        print(f"filled {p.relative_to(root)}")

    if blocked:
        sys.exit(
            "unresolved placeholders for versions being built:\n  "
            + "\n  ".join(blocked)
            + "\nrun: bash scripts/vendor.sh --versions <ver>"
        )
    if not changed:
        print("no FILL: placeholders left in versions/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
