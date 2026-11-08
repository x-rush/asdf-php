#!/usr/bin/env bash
# asdf-php v2 / macOS 原生构建（不能用 Docker：macOS 跑不了 Linux 容器）
#
#   bash build/macos.sh 8.1.34
#   bash build/macos.sh 7.4.33 --arch x86_64
#   bash build/macos.sh 7.4.33 --check          # 只检查依赖，不构建
#
# 与 Linux 轨道的三个本质差异，代码里都必须显式处理：
#
# 1) **做不到自包含**。Apple 不允许分发 libSystem / libc++，所以 macOS 制品不是
#    "解压即用"，而是绑定 MACOSX_DEPLOYMENT_TARGET。我们只带非系统依赖，并用
#    @loader_path rpath 把引用改成相对路径；剩下的靠系统。这不是偷懒，是平台约束。
#
# 2) **Homebrew 前缀随架构不同**（arm64=/opt/homebrew，Intel=/usr/local），
#    所以绝对不能用 pkg-config 的默认搜索路径，必须显式喂 -I/-L。
#
# 3) **现代 Clang 对 2014 年代的 C 代码极严**：implicit function declaration 和
#    函数指针不兼容在 Clang 15+ 是 error。PHP 5.x/7.2 必须降级成 warning 才编得动。
#    这不是"关掉严格性"，是这批代码早于该诊断存在。
#
# 诚实的边界：PHP 5.4/5.6 的 macOS 原生构建需要大量补丁，成功率最低；
# 7.2/7.3 次之；7.4+ 基本顺畅。CI 上先跑 7.4/8.x，5.x 视需求再投入。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }

ver=""
arch=""
check_only=0
allow_deps=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arch)         arch="${2:?--arch needs arm64|x86_64}"; shift 2 ;;
    --check)        check_only=1; shift ;;
    --install-deps) allow_deps=1; shift ;;
    -h|--help)      sed -n '2,25p' "$0"; exit 0 ;;
    -*)             die "unknown option $1" ;;
    *)              [ -z "$ver" ] || die "only one version at a time"; ver="$1"; shift ;;
  esac
done
[ -n "$ver" ] || die "usage: bash build/macos.sh <php-version> [--arch arm64|x86_64]"
[ "$(uname -s)" = Darwin ] || die "this script only runs on macOS"
[ -f "versions/$ver.toml" ] || die "no definition for $ver"

if [ -z "$arch" ]; then
  case "$(uname -m)" in
    arm64)  arch=arm64 ;;
    x86_64) arch=x86_64 ;;
    *)      die "unsupported arch $(uname -m)" ;;
  esac
fi
host_arch="$(uname -m)"
if [ "$arch" != "$host_arch" ]; then
  die "cross-building macOS $arch on $host_arch is not supported here: it needs the
       other Homebrew prefix and the other SDK slice, and half-broken cross builds
       are worse than none. Use a matching runner (macos-13=Intel, macos-14+=arm64)."
fi

step "0/6 read definition"
read -r generation < <(python3 - "versions/$ver.toml" <<'PY'
import sys, tomllib
print(tomllib.load(open(sys.argv[1], "rb")).get("generation", "g1"))
PY
)
php_major="$(printf '%s' "$ver" | cut -d. -f1)"
php_minor="$(printf '%s' "$ver" | cut -d. -f2)"
printf 'version: %s   generation: %s   arch: %s\n' "$ver" "$generation" "$arch"

# OpenSSL 选择：8.1 起才支持 3.0（bugs.php.net #81540）。5.x 只能用自建 1.0.2u。
if [ "$php_major" -ge 8 ] && [ "$php_minor" -ge 1 ]; then
  ossl_formula="openssl@3"
elif [ "$php_major" -ge 7 ]; then
  ossl_formula="openssl@1.1"
else
  ossl_formula=""     # 5.x：从 vendor 自建 1.0.2u，brew 早就不提供
fi

# 依赖清单：7.4 起 mbstring 需要外部 oniguruma；5.x/7.2/7.3 自带。
deps="bison re2c autoconf pkg-config libiconv libjpeg libpng freetype libzip curl"
[ -n "$ossl_formula" ] && deps="$deps $ossl_formula"
case "$php_major.$php_minor" in
  7.4|8.*) deps="$deps oniguruma" ;;
esac

step "1/6 dependencies"
command -v brew >/dev/null 2>&1 || die "Homebrew required: https://brew.sh"
missing=""
for f in $deps; do
  brew list --versions "$f" >/dev/null 2>&1 || missing="$missing $f"
done
if [ -n "$missing" ]; then
  echo "missing formulae:$missing"
  if [ "$allow_deps" = 1 ]; then
    # 显式确认才动用户的 brew：安装/升级 Homebrew 包是有副作用的外部操作。
    brew install $missing
  else
    die "install them first (or re-run with --install-deps): brew install$missing"
  fi
else
  echo "all formulae present"
fi
if [ -z "$ossl_formula" ]; then
  [ -s vendor/openssl-1.0.2u.tar.gz ] || die "PHP $ver needs OpenSSL 1.0.2u from vendor/: run bash scripts/vendor.sh --versions $ver"
fi
if [ "$check_only" = 1 ]; then
  echo; echo "(--check only: dependencies look usable, nothing was built)"; exit 0
fi

brew_prefix="$(brew --prefix)"
prefix="$root/build/prefix/$ver-$arch"
rm -rf "$prefix"
mkdir -p "$prefix"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-11.0}"

# Homebrew 是 keg-only 的：openssl、curl、libiconv 都不会进默认搜索路径，
# 所以 pkg-config 必须显式喂，不能指望它自己找到。
export PKG_CONFIG_PATH="$brew_prefix/lib/pkgconfig"
for f in $deps; do
  p="$(brew --prefix "$f" 2>/dev/null || true)"
  [ -n "$p" ] && [ -d "$p/lib/pkgconfig" ] && PKG_CONFIG_PATH="$PKG_CONFIG_PATH:$p/lib/pkgconfig"
done
export PATH="$(brew --prefix bison)/bin:$(brew --prefix re2c)/bin:$PATH"

step "2/6 toolchain"
if [ -z "$ossl_formula" ]; then
  # PHP 5.x 只认 OpenSSL 1.0.x，brew 早已移除；从 vendor 源码自建到本地。
  # 刻意用 no-shared 静态链接：1.0.2u 的 soname 是 libssl.1.0.0.dylib，
  # 动态带走它与 macOS 上其它用到 OpenSSL 的东西冲突概率不低，静态最省事。
  ossl_prefix="$root/build/toolchain/openssl-1.0.2u-$arch"
  if [ ! -x "$ossl_prefix/bin/openssl" ]; then
    case "$arch" in
      arm64)  ossl_target=darwin64-arm64-cc ;;
      x86_64) ossl_target=darwin64-x86_64-cc ;;
      *)      die "no OpenSSL 1.0.2u target for $arch" ;;
    esac
    echo "building OpenSSL 1.0.2u (vendor) -> $ossl_prefix"
    work="$(mktemp -d)"
    tar xzf vendor/openssl-1.0.2u.tar.gz -C "$work"
    ( cd "$work/openssl-1.0.2u"
      ./Configure --prefix="$ossl_prefix" no-shared -fPIC "$ossl_target"
      make -j"$(sysctl -n hw.ncpu)" >/dev/null
      make install_sw >/dev/null )
    rm -rf "$work"
  fi
  ossl_dir="$ossl_prefix"
  # PHP 5.x 的 buildconf 需要 bison 2.x；brew 只有 3.x，用 vendor 里的 2.7。
  bison_prefix="$root/build/toolchain/bison-2.7-$arch"
  if [ ! -x "$bison_prefix/bin/bison" ] && [ -s vendor/bison-2.7.tar.gz ]; then
    echo "building bison 2.7 (vendor) -> $bison_prefix"
    work="$(mktemp -d)"
    tar xzf vendor/bison-2.7.tar.gz -C "$work"
    ( cd "$work/bison-2.7"; ./configure --prefix="$bison_prefix" >/dev/null
      make -j"$(sysctl -n hw.ncpu)" >/dev/null; make install >/dev/null )
    rm -rf "$work"
  fi
  [ -x "$bison_prefix/bin/bison" ] && export PATH="$bison_prefix/bin:$PATH"
else
  ossl_dir="$(brew --prefix "$ossl_formula")"
fi
printf 'openssl: %s\n' "$ossl_dir"
bison --version | head -1

step "3/6 configure + make"
# Linux 的 toml flags 直接复用，只做两处平台改写：去掉 --with-libdir（macOS 无
# multiarch 这一层），把 --with-openssl 换成 Homebrew/自建的绝对路径。
python3 scripts/gen-build-inputs.py "$ver" >/dev/null
flags=""
while IFS= read -r f; do
  case "$f" in
    --with-libdir=*) : ;;
    --with-openssl=*) continue ;;
    --with-openssl)   continue ;;
    *) flags="$flags $f" ;;
  esac
done < "build/.gen/$ver.flags"
flags="$flags --with-openssl=$ossl_dir"
# macOS SDK 不再提供 curl 头文件，必须用 brew 的 curl 而不是系统的。
flags="$flags --with-curl=$(brew --prefix curl)"

clang_flags="-Wno-error=implicit-function-declaration -Wno-error=incompatible-function-pointer-types"
cflags="-O2 -I$ossl_dir/include -I$(brew --prefix curl)/include $clang_flags"
ldflags="-L$ossl_dir/lib -L$(brew --prefix curl)/lib -Wl,-rpath,$prefix/lib"
if [ -f "build/.gen/$ver.env" ]; then
  # toml 里的 CFLAGS 只在 Linux 有意义（-fcommon 等），这里只取额外选项。
  extra="$(sed -n 's/^CFLAGS="\(.*\)"$/\1/p' "build/.gen/$ver.env" | sed 's/-fcommon//g')"
  cflags="$cflags $extra"
fi

work="$(mktemp -d)"
tar xzf "vendor/php-$ver.tar.gz" -C "$work"
cd "$work/php-$ver"
# shellcheck disable=SC2086
CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure \
  --prefix="$prefix" \
  --with-config-file-path="$prefix/etc" \
  --with-config-file-scan-dir="$prefix/etc/conf.d" \
  $flags \
  || { echo "=== configure failed; config.log tail ==="; tail -n 200 config.log; exit 1; }
make -j"$(sysctl -n hw.ncpu)"
make install
mkdir -p "$prefix/etc/conf.d"
cd "$root"

step "4/6 extensions"
export PATH="$prefix/bin:$PATH"
while read -r name tgz mod; do
  [ -n "$name" ] || continue
  rm -rf "$work/ext-$name"; mkdir "$work/ext-$name"
  tar xzf "vendor/$tgz" -C "$work/ext-$name" --strip-components=1
  ( cd "$work/ext-$name"
    # 扩展编译同样要能看见 Homebrew 的 openssl/curl，否则 redis 拿不到 SSL。
    CFLAGS="$cflags" LDFLAGS="$ldflags" phpize >/dev/null
    CFLAGS="$cflags" LDFLAGS="$ldflags" ./configure --with-php-config="$prefix/bin/php-config" >/dev/null
    make -j"$(sysctl -n hw.ncpu)" >/dev/null
    make install >/dev/null )
  printf 'extension=%s.so\n' "$mod" > "$prefix/etc/conf.d/$mod.ini"
done < "build/.gen/$ver.ext"
"$prefix/bin/php" -m

step "5/6 relocation + package"
mkdir -p out
OUT_DIR="$root/out" sh scripts/pack-artifact.sh \
  "$prefix" "php-$ver-darwin-$arch.tar.gz" "$root/build/.gen/$ver.ext"

step "6/6 done"
art="out/php-$ver-darwin-$arch.tar.gz"
cat <<TIP
artifact: $art

Reminder — a macOS artifact is NOT self-contained the way a Linux one is:
  * libSystem / libc++ come from the OS, so this build is tied to
    MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET
  * non-system deps (openssl, curl, ...) are bundled and referenced via
    @loader_path, so do not move lib/ away from the prefix
  * arm64 binaries modified by install_name_tool were re-signed ad-hoc;
    if you re-package by hand, re-run: codesign --force --sign - <binary>

Smoke it on a CLEAN machine (or a fresh $TMPDIR) before publishing:
  bash scripts/smoke-artifact.sh $art $ver
TIP
