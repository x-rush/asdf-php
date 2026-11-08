#!/usr/bin/env python3
"""校验「定义里声明的 sha256」与「vendor 目录里实际下载到的字节」是否一致。

    python3 scripts/verify-hashes.py <repo-root> <vendor-dir>

为什么需要它：versions/*.toml 里的 sha256 如果只是被人写进去、没人真的比对过，
那它就不是冻结输入，只是装饰。下载完再算一遍、和声明值对不上就拒绝继续，才让
「源被上游换过 / 有人手改了定义」变成构建前的硬失败，而不是 -- 收集日志时才看出来
的怪错误。

只检查**已经在账本里**的文件：单版本构建（--versions）只拉它自己那几个输入，
其它版本声明的文件不在本地是正常的，不能因此报错。FILL: 占位同样跳过 —— 那是
「还没冻结」，由 scripts/fill-placeholders.py 负责填。
"""
from __future__ import annotations

import json
import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    sys.exit("python3.11+ required (tomllib); your python is too old")

FILL = "FILL:"


def declarations(doc: dict) -> list[tuple[str, str]]:
    """从一份版本定义里取出 (文件名, 声明的 sha256)。"""
    out: list[tuple[str, str]] = []
    src = doc.get("source", {})
    if isinstance(src, dict) and src.get("path"):
        out.append((pathlib.Path(src["path"]).name, src.get("sha256", "")))
    toolchain = doc.get("toolchain", {})
    if isinstance(toolchain, dict):
        for key in ("openssl", "bison"):
            tc = toolchain.get(key)
            if isinstance(tc, dict) and tc.get("path"):
                out.append((pathlib.Path(tc["path"]).name, tc.get("sha256", "")))
    return out


def main() -> int:
    if len(sys.argv) != 3:
        sys.exit("usage: verify-hashes.py <repo-root> <vendor-dir>")
    root, vendor = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

    ledger_path = vendor / "SOURCES.json"
    if not ledger_path.is_file():
        sys.exit(f"missing {ledger_path} — run vendor.sh first")
    ledger = json.loads(ledger_path.read_text(encoding="utf-8"))

    bad: list[str] = []
    checked = 0
    absent = 0
    for p in sorted((root / "versions").glob("*.toml")):
        with p.open("rb") as fh:
            doc = tomllib.load(fh)
        for name, declared in declarations(doc):
            if not declared or declared.startswith(FILL):
                continue
            actual = ledger.get(name, {}).get("sha256")
            if not actual:
                absent += 1
                continue
            checked += 1
            if actual != declared:
                bad.append(
                    f"{p.name}: {name}\n"
                    f"    declared {declared}\n"
                    f"    vendored {actual}"
                )

    if bad:
        print("hash mismatch between definition and downloaded bytes:", file=sys.stderr)
        for b in bad:
            print(f"  {b}", file=sys.stderr)
        print(
            "refusing to continue: either the upstream tarball changed or the "
            "definition was edited by hand. Neither is safe to build.",
            file=sys.stderr,
        )
        return 1

    print(f"hash check: {checked} declared input(s) match vendor/SOURCES.json")
    if absent:
        print(f"            {absent} declared input(s) not downloaded in this run (skipped)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
