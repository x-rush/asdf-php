#!/usr/bin/env bash
# asdf-php v2 / 一次性 vendor：把源码与工具链固化进 vendor/，构建期零外联
#
#   bash scripts/vendor.sh            下载 + 算 sha256 + 写 vendor/SOURCES.json
#   bash scripts/vendor.sh --write   额外把真实 sha256 回填 versions/5.4.45.toml
#
# 只在首次接入、或上游托管链变化时跑一次。之后 CI 只读 vendor/，不再联网取源码。
# 任何 URL 失效都会立刻报错，不会静默拿一个 HTML 错误页当源码。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vendor="$root/vendor"
mkdir -p "$vendor"

PHP_URL="${PHP_URL:-https://museum.php.net/php5/php-5.4.45.tar.gz}"
# 核实过：openssl.org/source/old/1.0.2/ 目录 404，但该文件 URL 302 跳到 GitHub releases，curl -L 可跟。
OPENSSL_URL="${OPENSSL_URL:-https://www.openssl.org/source/old/1.0.2/openssl-1.0.2u.tar.gz}"
# GNU 镜像若调整，用 BISON_URL 覆盖；下载结果会做 gzip 校验，错源会直接失败。
BISON_URL="${BISON_URL:-https://ftp.gnu.org/gnu/bison/bison-2.7.tar.gz}"
# 扩展源码同样必须冻结：2.2.8 是 phpredis 最后一个支持 PHP < 7 的分支
# （6.3.0 的 PECL 依赖要求 PHP >= 7.4.0）；swoole 1.10.5 是 1.x 末版。
REDIS_URL="${REDIS_URL:-https://pecl.php.net/get/redis-2.2.8.tgz}"
SWOOLE_URL="${SWOOLE_URL:-https://pecl.php.net/get/swoole-1.10.5.tgz}"

write_defs=0
[ "${1:-}" = "--write" ] && write_defs=1
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != "--write" ]; }; then
  echo "usage: $0 [--write]" >&2
  exit 2
fi

fetch() {
  # bash 会先展开整行再做赋值：同一条 local 里引用 $name 会在 set -u 下
  # 报 "name: unbound variable"。必须拆成两句，先赋值 name 再算 dest。
  local name="$1" url="$2"
  local dest="$vendor/$name"
  if [ -s "$dest" ]; then
    echo "cached  $name"
  else
    echo "fetch   $name <- $url"
    curl -fL --retry 3 --connect-timeout 15 -o "$dest.part" "$url"
    mv "$dest.part" "$dest"
  fi
  if ! gzip -t "$dest" 2>/dev/null; then
    echo "vendor: $name is not a valid gzip tarball — check the URL (likely an HTML error page)" >&2
    exit 1
  fi
}

fetch php-5.4.45.tar.gz "$PHP_URL"
fetch openssl-1.0.2u.tar.gz "$OPENSSL_URL"
fetch bison-2.7.tar.gz "$BISON_URL"
fetch redis-2.2.8.tgz "$REDIS_URL"
fetch swoole-1.10.5.tgz "$SWOOLE_URL"

# Debian 归档签名公钥同样是冻结输入，CI 不联网取 keyring。
# 若 L2 的 apt-get update 验签报 NO_PUBKEY，把 Release 签名者对应的 asc
# 用 DEBIAN_KEY_URL 覆盖后重跑即可；不猜测、不伪造 key。
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

# CI 的 "Frozen inputs present and intact" 步骤逐文件比对这些 sha256
python3 - "$vendor" <<'PY'
import hashlib, json, pathlib, sys
v = pathlib.Path(sys.argv[1])
names = ["php-5.4.45.tar.gz", "openssl-1.0.2u.tar.gz", "bison-2.7.tar.gz",
         "redis-2.2.8.tgz", "swoole-1.10.5.tgz"]
out = {n: {"sha256": hashlib.sha256((v / n).read_bytes()).hexdigest()} for n in names}
(v / "SOURCES.json").write_text(json.dumps(out, indent=2) + "\n")
for n, m in out.items():
    print(f"{n}  {m['sha256']}")
PY

if [ "$write_defs" = 1 ]; then
  python3 - "$root" "$vendor" <<'PY'
import json, pathlib, re, sys
root, vendor = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
src = json.loads((vendor / "SOURCES.json").read_text())
p = root / "versions/5.4.45.toml"
text = p.read_text()
# definition.toml 中三个占位按 [source] -> openssl -> bison 的顺序出现
order = ["php-5.4.45.tar.gz", "openssl-1.0.2u.tar.gz", "bison-2.7.tar.gz"]
expected = [src[n]["sha256"] for n in order]
n_holes = text.count("FILL_AFTER_FIRST_VENDOR")
if n_holes == 0:
    # 幂等：已回填过就校验与当前 vendor 一致，绝不静默覆盖
    found = re.findall(r'sha256\s*=\s*"([0-9a-f]{64})"', text)
    if found != expected:
        raise SystemExit("definition.toml sha256 disagree with vendor/SOURCES.json; refusing to overwrite")
    print("sha256 already present and match SOURCES.json; nothing to write")
else:
    if n_holes != len(order):
        raise SystemExit(f"expected {len(order)} placeholders, found {n_holes}; refusing a partial write")
    for h in expected:
        text = text.replace("FILL_AFTER_FIRST_VENDOR", h, 1)
    if "FILL_AFTER_FIRST_VENDOR" in text:
        raise SystemExit("placeholders remain; refusing a partial write")
    p.write_text(text)
    print("wrote real sha256 into", p.relative_to(root))
PY
fi

cat <<'TIP'

All build inputs are frozen; no manual input remains before an L2 build:
  * base image digest -- build/Dockerfile.5.4 + versions/5.4.45.toml
    (debian:jessie@sha256:32ad5050..., obtained in WSL on 2026-11-08)
  * keys/jessie.gpg  -- dearmored from the Debian archive key
  * 5 source tarballs + sha256 -- vendor/SOURCES.json
Still TODO after L2 passes (not blocking the build):
  * mirror that digest into your own registry (tags are not frozen), then
    update BASE_IMAGE in Dockerfile.5.4 and the definition.
  * publish the artifact + .sha256 to Releases, then fill manifest.json.
  * run the legacy CI workflow once to verify the gates.

L2 status (2026-11-08): docker build + smoke fully green. redis 2.2.8 and
swoole 1.10.5 both compile on PHP 5.4.45 and load after the artifact is
unpacked to an arbitrary path; the old "swoole unproven / degrade to WARN"
note is retired. smoke now FAILs on a missing extension — never publish
an artifact that only passes with WARNs.
TIP
