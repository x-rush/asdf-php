#!/usr/bin/env python3
"""把 versions/<ver>.toml 展开成构建期需要的三个纯文本文件。

    python3 scripts/gen-build-inputs.py 7.4.33

产出（都在 build/.gen/ 下，已 gitignore）：
    <ver>.flags  每行一个 configure flag，Dockerfile 用 $(cat ...) 做词分割
    <ver>.env    CFLAGS / LDFLAGS，Dockerfile 用 `. file` 引入（可能为空文件）
    <ver>.ext    每行 "name tarball module"，扩展按此顺序编译

为什么要这一步：configure flags 必须只有一个真相源。以前 5.4 是「Dockerfile 里
写死一份 + toml 里再抄一份」，两处迟早漂移；而 flags 漂移的后果不是报错，是某个
扩展静默缺席（--with-mysql 在 PHP 7.0 被移除、--with-gd 在 8.1 改名成 --enable-gd，
都只警告不失败）。所以这里既做展开，也做**已知雷区的硬拦截**。
"""
from __future__ import annotations

import pathlib
import sys

try:
    import tomllib
except ModuleNotFoundError:  # pragma: no cover
    sys.exit("python3.11+ required (tomllib); your python is too old")

root = pathlib.Path(__file__).resolve().parent.parent
gen = root / "build" / ".gen"

# 已知会「静默失去功能」的 flag 漂移，按 PHP 版本区间拦截。
# 这类错误编译器不会报，只会在运行时 class_exists/function_exists 里露馅，
# 所以宁可在生成构建输入时就停下来。
FORBIDDEN = [
    # (flag 前缀, 起始版本, 结束版本, 原因)
    ("--with-mysql", (7, 0), (99, 99), "ext/mysql 在 PHP 7.0 被移除，写了也不生效，只会让 mysql 扩展缺席"),
    ("--enable-zip", (7, 2), (99, 99), "PHP 7.2 起 zip 改用 libzip，flag 是 --with-zip"),
    ("--with-gd", (8, 1), (99, 99), "PHP 8.1 起 GD 开关是 --enable-gd，--with-gd 只警告不生效"),
    ("--with-freetype-dir", (7, 4), (99, 99), "PHP 7.4 起改名为 --with-freetype"),
    ("--with-jpeg-dir", (7, 4), (99, 99), "PHP 7.4 起改名为 --with-jpeg"),
    ("--with-png-dir", (7, 4), (99, 99), "PHP 7.4 起 png 由 libpng pkg-config 自动发现"),
    ("--with-openssl=", (8, 1), (99, 99), "G3 用系统 OpenSSL 3.0，不再指向自建前缀"),
]


def vtuple(v: str) -> tuple[int, int]:
    parts = v.split(".")
    return int(parts[0]), int(parts[1])


def matches(flag: str, prefix: str) -> bool:
    """严格匹配，避免 --with-mysql 把 --with-mysqli 一起误伤。"""
    if prefix.endswith("="):
        return flag.startswith(prefix)
    return flag == prefix or flag.startswith(prefix + "=")


def main() -> int:
    if len(sys.argv) != 2:
        sys.exit("usage: gen-build-inputs.py <php-version>")
    ver = sys.argv[1]
    toml_path = root / "versions" / f"{ver}.toml"
    if not toml_path.is_file():
        sys.exit(f"missing definition: {toml_path.relative_to(root)}")

    with toml_path.open("rb") as fh:
        d = tomllib.load(fh)
    if d.get("version") != ver:
        sys.exit(f"{toml_path.name}: version={d.get('version')!r} != {ver!r}")

    flags = list(d.get("configure", {}).get("flags", []))
    if not flags:
        sys.exit(f"{ver}: no [configure].flags")

    v = vtuple(ver)
    for flag in flags:
        for prefix, lo, hi, why in FORBIDDEN:
            if matches(flag, prefix) and lo <= v <= hi:
                sys.exit(f"{ver}: flag {flag!r} is wrong for this version — {why}")

    # 跨代污染：G2/G3 用系统 OpenSSL，出现自建 toolchain 路径说明抄错了模板。
    gen_id = d.get("generation", "")
    if gen_id in ("g2", "g3") and any("/opt/toolchain" in f for f in flags):
        sys.exit(f"{ver}: {gen_id} must use the system OpenSSL, not /opt/toolchain")

    gen.mkdir(parents=True, exist_ok=True)
    (gen / f"{ver}.flags").write_text("\n".join(flags) + "\n", encoding="utf-8", newline="\n")

    # CFLAGS / LDFLAGS 走 env 文件而不是 build-arg：带空格的字符串过 docker
    # --build-arg 时引号处理很容易出错，文件是唯一无歧义的传递方式。
    env_lines = []
    for key, toml_key in (("CFLAGS", "cflags"), ("LDFLAGS", "ldflags")):
        val = d.get("build", {}).get(toml_key, "").strip()
        if val:
            env_lines.append(f'{key}="{val}"')
    (gen / f"{ver}.env").write_text("\n".join(env_lines) + ("\n" if env_lines else ""), encoding="utf-8", newline="\n")

    exts = d.get("extensions", {})
    # redis 先编、swoole 后编：swoole 的 configure 会探测已装扩展，顺序固定便于复现。
    order = sorted(exts, key=lambda n: (n not in ("redis",), n))
    lines = [f"{name} {name}-{exts[name]}.tgz {name}" for name in order]
    if not lines:
        sys.exit(f"{ver}: no [extensions] — every supported version must ship redis+swoole")
    (gen / f"{ver}.ext").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")

    print(f"{ver}: {len(flags)} flags, {len(lines)} extensions -> build/.gen/{ver}.{{flags,env,ext}}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
