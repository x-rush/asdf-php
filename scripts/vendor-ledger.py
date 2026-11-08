#!/usr/bin/env python3
"""维护 vendor/SOURCES.json：已有条目保留，本次下载到的更新；只增不减。

    python3 scripts/vendor-ledger.py <vendor-dir>

为什么是合并而不是重算：CI 每次只为一个版本拉取源码（全量 80MB 不该进流水线），
如果按目录重算，一次构建就会把另外六个版本的记录删掉，于是「拉完 vendor 之后
git diff 必须为空」这条漂移门禁永远红灯，最后只能被关掉 —— 而它正是冻结契约
唯一真正生效的地方。

副作用是有意保留的：某个版本从定义里移除后，它的旧记录仍留在 SOURCES.json 里。
这是历史账本，不是当前状态的镜像；要清理请人工确认后单独提交。
"""
from __future__ import annotations

import hashlib
import json
import pathlib
import sys


def rebuild(vendor: pathlib.Path) -> dict[str, dict[str, str]]:
    ledger = vendor / "SOURCES.json"
    out = json.loads(ledger.read_text(encoding="utf-8")) if ledger.is_file() else {}
    for p in sorted(vendor.iterdir()):
        if not p.is_file():
            continue
        if not (p.name.endswith(".tar.gz") or p.name.endswith(".tgz")):
            continue
        digest = hashlib.sha256(p.read_bytes()).hexdigest()
        old = out.get(p.name, {}).get("sha256")
        if old and old != digest:
            print(
                f"NOTE: {p.name} hash changed ({old[:12]}… -> {digest[:12]}…); "
                f"upstream drift or a re-uploaded source",
                file=sys.stderr,
            )
        out[p.name] = {"sha256": digest}
    ledger.write_text(json.dumps(dict(sorted(out.items())), indent=2) + "\n", encoding="utf-8", newline="\n")
    return out


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit("usage: vendor-ledger.py <vendor-dir>")
    vendor = pathlib.Path(sys.argv[1])
    if not vendor.is_dir():
        sys.exit(f"not a directory: {vendor}")
    for name, meta in sorted(rebuild(vendor).items()):
        print(f"{name}  {meta['sha256']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
