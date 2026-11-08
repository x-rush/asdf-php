#!/usr/bin/env bash
# asdf-php v2 / vendor：把每个版本的源码输入固化到 vendor/，构建期零外联
#
#   bash scripts/vendor.sh                       全部版本（首次约 80MB）
#   bash scripts/vendor.sh --versions 7.4.33     只取某个版本需要的输入
#   bash scripts/vendor.sh --write               额外把真实 sha256 回填 versions/*.toml
#
# 真相源是 versions/*.toml：每个版本声明自己要哪些文件，这里只负责下载、校验、
# 记账、回填，不维护第二份清单。旧的写法把 5 个文件名写死在脚本里，加一个版本
# 就得改脚本 —— 版本数从 1 涨到 7 之后那套就没法用了。
#
# 回填用 FILL:<filename> 占位，不是「按顺序填三个洞」：G2/G3 只有 PHP 源码一个
# 输入（OpenSSL 用系统库），按位置填必然错位。占位符自带文件名，顺序无关。
#
# 任何 URL 失效都会立刻报错，不会静默拿一个 HTML 错误页当源码（gzip -t 兜底）。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/vendor"
mkdir -p "$vendor"

write_defs=0
only=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --write)    write_defs=1; shift ;;
    --versions) only="${2:?--versions needs a comma-separated list}"; shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "usage: $0 [--write] [--versions a,b,c]" >&2; exit 2 ;;
  esac
done

# ---- 1) 从所有 toml 汇总出 (文件名, URL) 计划 ------------------------------
plan="$(python3 - "$root" "$only" <<'PY'
import pathlib, sys, tomllib

root = pathlib.Path(sys.argv[1])
only = {v.strip() for v in sys.argv[2].split(",") if v.strip()}

# 工具链只有 G1 需要，URL 固定；其它版本从 toml 的 [source].url 取。
TOOLCHAIN = {
    "openssl-1.0.2u.tar.gz": "https://www.openssl.org/source/old/1.0.2/openssl-1.0.2u.tar.gz",
    "bison-2.7.tar.gz": "https://ftp.gnu.org/gnu/bison/bison-2.7.tar.gz",
}
PECL = ("redis", "swoole")

rows: dict[str, str] = {}
for p in sorted((root / "versions").glob("*.toml")):
    with p.open("rb") as fh:
        d = tomllib.load(fh)
    ver = d.get("version", p.stem)
    if only and ver not in only:
        continue
    src = d.get("source", {})
    if src:
        name = pathlib.Path(src["path"]).name
        url = src.get("url", "")
        if not url:
            sys.exit(f"{p.name}: [source] has no url")
        rows[name] = url
    for key in ("openssl", "bison"):
        tc = d.get("toolchain", {}).get(key)
        if isinstance(tc, dict):
            name = pathlib.Path(tc["path"]).name
            rows[name] = TOOLCHAIN.get(name) or sys.exit(f"unknown toolchain url for {name}")
    for ext, ver_ in d.get("extensions", {}).items():
        if ext not in PECL:
            sys.exit(f"{p.name}: unsupported extension {ext!r}")
        name = f"{ext}-{ver_}.tgz"
        rows[name] = f"https://pecl.php.net/get/{name}"

if not rows:
    sys.exit("no build inputs selected — check versions/ and --versions")
for name, url in rows.items():
    print(f"{name}\t{url}")
PY
)"

printf 'planned inputs: %s\n' "$(printf '%s\n' "$plan" | wc -l | tr -d ' ')"

# ---- 2) 下载 + gzip 校验 ---------------------------------------------------
fetch() {
  # bash 会先展开整行再做赋值：同一条 local 里引用 $name 会在 set -u 下
  # 报 "name: unbound variable"。必须拆成两句。
  local name="$1" url="$2"
  local dest="$vendor/$name"
  if [ -s "$dest" ]; then
    echo "cached  $name"
  else
    echo "fetch   $name <- $url"
    curl -fL --retry 3 --connect-timeout 20 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  if ! gzip -t "$dest" 2>/dev/null; then
    echo "vendor: $name is not a valid gzip tarball — check the URL (likely an HTML error page)" >&2
    exit 1
  fi
}

while IFS=$'\t' read -r name url; do
  [ -n "$name" ] || continue
  fetch "$name" "$url"
done <<< "$plan"

# ---- 3) Debian 归档签名公钥（只有 G1 的 jessie 需要） -----------------------
DEBIAN_KEY_URL="${DEBIAN_KEY_URL:-https://ftp-master.debian.org/keys/archive-key-8.asc}"
mkdir -p "$root/keys"
if [ -s "$root/keys/jessie.gpg" ]; then
  echo "cached  keys/jessie.gpg"
elif command -v gpg >/dev/null 2>&1; then
  echo "fetch   keys/jessie.gpg <- $DEBIAN_KEY_URL"
  curl -fL --retry 3 --connect-timeout 15 -o "$vendor/jessie-key.asc" "$DEBIAN_KEY_URL"
  if ! grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$vendor/jessie-key.asc"; then
    echo "vendor: jessie key is not a PGP public key block — check DEBIAN_KEY_URL" >&2
    exit 1
  fi
  gpg --batch --yes --dearmor -o "$root/keys/jessie.gpg" "$vendor/jessie-key.asc"
else
  echo "NOTE: gpg not found; export the Debian archive key into keys/jessie.gpg manually" >&2
fi

# ---- 4) 记账：SOURCES.json 是完整性契约，CI 逐文件比对 ----------------------
# 合并语义（只增不减）在 vendor-ledger.py 里，配套的 T3k 会验它不会把
# 本次没下载的版本记录删掉 —— 否则 CI 每次单版本构建都会把漂移门禁变成永久红灯。
python3 "$root/scripts/vendor-ledger.py" "$vendor"

# ---- 5) 回填 versions/*.toml ----------------------------------------------
# 门禁按 --versions 作用域，见 scripts/fill-placeholders.py 文件头：过去它扫描
# 全部 toml，任何一个还没轮到冻结的版本都会让单版本构建在第一步就死掉。
if [ -n "$only" ]; then
  python3 "$root/scripts/fill-placeholders.py" "$root" "$vendor" --scope "$only"
else
  python3 "$root/scripts/fill-placeholders.py" "$root" "$vendor"
fi

cat <<'TIP'

All declared build inputs are frozen. Remaining manual step before an L2 build:
  * resolve the base image index digest per generation:
      bash scripts/pin-base.sh debian:bullseye-slim    # G2
      bash scripts/pin-base.sh debian:bookworm-slim    # G3
      bash scripts/pin-base.sh debian:jessie           # G1 arm64 覆盖性确认
    pin-base.sh 会顺带确认 index 里确实有 linux/amd64 与 linux/arm64，
    没通过就别建 arm64 —— 那是「构建到一半才发现」的典型来源。
TIP
