#!/bin/sh
# asdf-php v2 / 制品打包器（构建期最后一步，不进运行时）
#
#   sh scripts/pack-artifact.sh <prefix> <artifact-name> [extfile]
#
# 三件事一步做完，Linux 与 macOS 共用同一份实现：
#   1) 把 prefix 变成「解压到任意路径即可用」：随包带走非系统 soname/dylib、
#      bin/php 换成 wrapper、conf.d 的 extension_dir 改为 ${ASDF_PHP_PREFIX} 插值
#   2) 做一次「真实重定位自检」：把 prefix 搬到陌生路径、原路径不再存在，
#      然后验版本、验每个扩展、验 php-config --prefix —— 原路径还在时这个测试
#      会假通过，所以必须物理搬走
#   3) 打 tar.gz + .sha256 sidecar
#
# 为什么单独抽出来：G1/G2/G3 三套 Dockerfile 和 macOS 原生构建共用这段逻辑，
# 复制三份必然会漂移（改了 Linux 忘了 macOS），而这里每个平台差异都是有意的。
#
# 平台差异（都要显式处理，不能靠运气）：
#   Linux  : ldd 枚举依赖；排除 glibc 家族（宿主机 libc 更新，塞旧 libc 反而炸）
#   macOS  : otool -L 枚举依赖；/usr/lib 与 /System 由 OS 提供，不能打包
#            （Apple 不允许分发 libSystem，打包既违约也会因签名失效起不来）；
#            用 @loader_path rpath 而不是 DYLD_LIBRARY_PATH，因为后者会被 SIP
#            对受保护进程剥掉；改写过的 Mach-O 必须重新 ad-hoc 签名（arm64 强制）
set -eu

prefix="${1:?usage: pack-artifact.sh <prefix> <artifact-name> [extfile]}"
art="${2:?usage: pack-artifact.sh <prefix> <artifact-name> [extfile]}"
extfile="${3:-}"
out="${OUT_DIR:-/out}"

[ -d "$prefix/bin" ] || { echo "FATAL: not a PHP prefix tree: $prefix" >&2; exit 1; }
prefix="$(cd "$prefix" && pwd)"
os="$(uname -s)"
case "$os" in
  Darwin) family=darwin ;;
  Linux)  family=linux ;;
  *) echo "FATAL: unsupported build OS: $os" >&2; exit 1 ;;
esac

hash_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else echo "FATAL: no sha256 tool" >&2; return 1
  fi
}

wanted_exts=""
if [ -n "$extfile" ] && [ -f "$extfile" ]; then
  wanted_exts="$(awk 'NF >= 3 {print $3}' "$extfile" | tr '\n' ' ')"
fi

mkdir -p "$prefix/lib" "$prefix/libexec"

# ---------------------------------------------------------------------------
# 1) 随包带走运行期依赖
# ---------------------------------------------------------------------------
case "$family" in
linux)
  # 自建 OpenSSL（G1）不在系统搜索路径里，先把它加进来再 ldd，否则会漏掉。
  for d in "$prefix"/../toolchain/openssl-*/lib/*/ /opt/toolchain/openssl-*/lib/*/; do
    [ -d "$d" ] && LD_LIBRARY_PATH="$d${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  done
  export LD_LIBRARY_PATH
  find "$prefix" -type f \( -name 'php' -o -name 'php-cgi' -o -name '*.so' \) -print > /tmp/pack.elfs
  : > /tmp/pack.needed
  while IFS= read -r f; do
    ldd "$f" 2>/dev/null | awk '/=> \// {print $3}' >> /tmp/pack.needed
  done < /tmp/pack.elfs
  # glibc 家族刻意不打包：宿主机版本更新，塞旧 libc 反而会炸。
  sort -u /tmp/pack.needed \
    | grep -vE '/(ld-linux|libc\.so|libm\.so|libpthread\.so|libdl\.so|librt\.so|libresolv\.so|libnsl\.so|libutil\.so|libanl\.so|libcrypt\.so|libgcc_s\.so|libstdc\+\+\.so)' \
    > /tmp/pack.copy || true
  ;;
darwin)
  # macOS 上 tar 会把扩展属性打成 ._* 垃圾文件，必须关掉。
  COPYFILE_DISABLE=1; export COPYFILE_DISABLE
  find "$prefix" -type f -perm -u+x -print > /tmp/pack.elfs
  : > /tmp/pack.needed
  while IFS= read -r f; do
    # 不是 Mach-O 的就跳过（wrapper 脚本、ini、php 源码文件等）
    otool -L "$f" >/dev/null 2>&1 || continue
    otool -L "$f" | awk 'NR > 1 {print $1}' >> /tmp/pack.needed
  done < /tmp/pack.elfs
  # 系统库与相对引用一律不打包；@rpath/@loader_path 已经是可重定位写法。
  sort -u /tmp/pack.needed \
    | grep -vE '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' \
    > /tmp/pack.copy || true
  ;;
esac

while IFS= read -r so; do
  [ -n "$so" ] || continue
  [ -r "$so" ] || { echo "FATAL: unresolved runtime lib $so" >&2; exit 1; }
  cp -L -- "$so" "$prefix/lib/$(basename "$so")"
done < /tmp/pack.copy

test -n "$(ls -A "$prefix/lib")" || { echo "FATAL: bundled lib dir is empty" >&2; exit 1; }
printf 'bundled runtime libraries: %s\n' "$(find "$prefix/lib" -type f | wc -l | tr -d ' ')"

# macOS：把绝对 load path 改写成 @loader_path 相对路径，否则换机器 dyld 找不到。
if [ "$family" = darwin ]; then
  fix_macho() { # <binary> <is_lib>
    bin="$1" islib="$2"
    otool -L "$bin" | awk 'NR > 1 {print $1}' | while IFS= read -r dep; do
      case "$dep" in
        /usr/lib/*|/System/*|@rpath/*|@loader_path/*|@executable_path/*) continue ;;
      esac
      base="$(basename "$dep")"
      [ -f "$prefix/lib/$base" ] || continue
      if [ "$islib" = 1 ]; then
        install_name_tool -change "$dep" "@loader_path/$base" "$bin" 2>/dev/null || true
        install_name_tool -id "@loader_path/$base" "$bin" 2>/dev/null || true
      else
        install_name_tool -change "$dep" "@loader_path/../lib/$base" "$bin" 2>/dev/null || true
      fi
    done
    # 改过 Mach-O 就等于破坏签名；Apple Silicon 上签名无效的二进制直接 SIGKILL，
    # 必须重新 ad-hoc 签名（-s - 即 ad-hoc）。
    if command -v codesign >/dev/null 2>&1; then
      codesign --force --sign - "$bin" >/dev/null 2>&1 || true
    fi
  }
  for f in "$prefix"/lib/*.dylib "$prefix"/lib/*.so; do
    [ -f "$f" ] && fix_macho "$f" 1
  done
  find "$prefix" -type f -perm -u+x | while IFS= read -r f; do
    case "$f" in "$prefix"/lib/*) continue ;; esac
    otool -L "$f" >/dev/null 2>&1 && fix_macho "$f" 0
  done
fi

# ---------------------------------------------------------------------------
# 2) 重定位（ini 扫描目录 / extension_dir / 配套脚本里的字面前缀）
# ---------------------------------------------------------------------------
sh "$(dirname "$0")/relocate.sh" "$prefix"

# ---------------------------------------------------------------------------
# 3) 真实重定位自检：搬到陌生路径，原路径不存在了再验
# ---------------------------------------------------------------------------
parent="$(dirname "$prefix")"
base="$(basename "$prefix")"
scratch="$parent/.relocate-check.$$"
mv "$prefix" "$scratch"
# 中途失败或被 Ctrl-C / SIGTERM 打断也要搬回去：否则 prefix 会以
# .relocate-check.<pid> 的名字留在原地，下一次构建看到的是一个空目录，
# 报错完全指不到真正原因。四个信号都兜住。
trap 'mv "$scratch" "$prefix" 2>/dev/null || true' EXIT INT TERM HUP

"$scratch/bin/php" -v
for e in $wanted_exts; do
  "$scratch/bin/php" -m | grep -qi "^${e}$" \
    || { echo "FATAL: extension $e not loaded after relocation (extension_dir broken)" >&2; exit 1; }
done
if [ -x "$scratch/bin/php-config" ]; then
  got="$(cd "$scratch" && ./bin/php-config --prefix 2>/dev/null || true)"
  [ "$got" = "$scratch" ] \
    || { echo "FATAL: php-config --prefix=$got (expected $scratch)" >&2; exit 1; }
fi
mv "$scratch" "$prefix"
trap - EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# 4) 打包
# ---------------------------------------------------------------------------
mkdir -p "$out"
tar -czf "$out/$art" -C "$prefix" .
hash_of "$out/$art" > "$out/$art.sha256"
printf 'artifact: %s  sha256=%s\n' "$art" "$(cat "$out/$art.sha256")"
