#!/usr/bin/env bash
# asdf-php v2 / L2 artifact smoke test
#
#   bash scripts/smoke-artifact.sh out/php-5.4.45-linux-x86_64.tar.gz 5.4.45
#
# Run this AFTER the isolated docker build, before publishing to Releases.
# It only inspects the tarball; it does not install anything system-wide.
set -euo pipefail

art="${1:?usage: $0 <artifact.tar.gz> [expected-version]}"
expected="${2:-}"
[ -f "$art" ] || { echo "  [FAIL] missing artifact: $art" >&2; exit 1; }

# 1) checksum sidecar produced by the Dockerfile
if [ -f "$art.sha256" ]; then
  want="$(awk 'NR==1{print $1}' "$art.sha256")"
  if command -v sha256sum >/dev/null 2>&1; then got="$(sha256sum "$art" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then got="$(shasum -a 256 "$art" | awk '{print $1}')"
  else echo "  [FAIL] no sha256 tool"; exit 1; fi
  if [ "$want" = "$got" ]; then echo "  [PASS] sha256 sidecar matches"
  else echo "  [FAIL] sha256 mismatch: want=$want got=$got"; exit 1; fi
else
  echo "  [WARN] no .sha256 sidecar — CI must produce one before publishing"
fi

# 2) unpack + executable bin/php
# Use a RELATIVE temp dir: on MinGW an absolute Windows path breaks tar's -C,
# and a relative path survives the same code on WSL/Linux unchanged.
d="$(mktemp -d ./.asdf-php-smoke.XXXXXX)"
trap 'rm -rf -- "$d" 2>/dev/null || true' EXIT
if ! tar -xzf "$art" -C "$d"; then echo "  [FAIL] tarball is corrupt"; exit 1; fi
if [ ! -x "$d/bin/php" ]; then echo "  [FAIL] artifact has no executable bin/php"; exit 1; fi
echo "  [PASS] unpack -> bin/php executable"

# 2b) 自包含布局（A 方案）：随包 soname + wrapper 后面的真实 ELF。
# 老制品/第三方制品可能没这层，这里只告警；真正的可移植性由下面 3b 的
# ldd 硬断言兜底，避免把 smoke 退化成「只能验自己产物」的工具。
bundled="$(find "$d/lib" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
if [ "${bundled:-0}" -gt 0 ]; then
  echo "  [PASS] self-contained: $bundled shared libs bundled in lib/"
  if [ -x "$d/libexec/php.bin" ]; then
    echo "  [PASS] bin/php wrapper -> libexec/php.bin"
  else
    echo "  [WARN] lib/ present but libexec/php.bin missing; wrapper may be broken"
  fi
else
  echo "  [WARN] no bundled lib/ — artifact is NOT portable to another host"
fi

# 3) reported version
# 制品在 jessie 上编译，解包后直接在宿主执行常因缺老 soname 而启动失败
# （libpng12.so.0 / libmcrypt.so.4 / libzip.so.2 / libicu*.so.52 ...）。
# 原来把 stderr 丢进 /dev/null，只会看到 "got <empty>"；这里保留真实错误并
# 补一条 ldd 诊断，下一轮能一次定位到具体缺哪个库。
probe="$("$d/bin/php" -r 'echo PHP_VERSION;' 2>&1 || true)"
v="$(printf '%s\n' "$probe" | sed -n 's/^\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)"
echo "  [INFO] PHP_VERSION=${v:-<unavailable>}"
if [ -z "$v" ]; then
  echo "  [DIAG] bin/php could not start on this host:"
  printf '%s\n' "$probe" | sed 's/^/         /' | head -8
  if command -v ldd >/dev/null 2>&1; then
    # 自包含制品的 bin/php 是 shell wrapper，ldd 要看它背后的真实 ELF，
    # 并且把随包的 lib/ 放进 loader 搜索路径，否则全是误报。
    ldd_target="$d/bin/php"
    [ -x "$d/libexec/php.bin" ] && ldd_target="$d/libexec/php.bin"
    echo "  [DIAG] unresolved shared libraries (with bundled lib/):"
    LD_LIBRARY_PATH="$d/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      ldd "$ldd_target" 2>&1 | grep -i 'not found' | sed 's/^/         /' || true
  fi
fi
if [ -n "$expected" ]; then
  if [ "$v" = "$expected" ]; then echo "  [PASS] version == $expected"
  else echo "  [FAIL] expected $expected, got ${v:-<empty>}"; exit 1; fi
fi

# 3b) 带着制品自带的 lib/ 解析所有 ELF：任何 "not found" 都说明自包含没做全。
# 这是「换台机器能不能跑」的硬断言，比在构建容器里 php -v 更有说服力。
# macOS 走另一条路：Apple 不允许分发 libSystem，所以 macOS 制品谈不上自包含，
# 能验的是「非系统依赖是否都改成了 @loader_path/@rpath 相对引用」——
# 只要还有一条 /usr/local 或构建目录的绝对路径，换台机器就是 dyld 报错。
if [ -d "$d/lib" ] && command -v ldd >/dev/null 2>&1; then
  unresolved=0
  while IFS= read -r f; do
    miss="$(LD_LIBRARY_PATH="$d/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
      ldd "$f" 2>&1 | grep -i 'not found' || true)"
    if [ -n "$miss" ]; then
      echo "  [FAIL] unresolved sonames in $f:"
      printf '%s\n' "$miss" | sed 's/^/         /' | head -8
      unresolved=1
    fi
  done < <(find "$d" -type f \( -name '*.so' -o -name '*.bin' \) -print)
  if [ "$unresolved" -eq 0 ]; then
    echo "  [PASS] all bundled ELFs resolve with lib/ on the loader path"
  else
    exit 1
  fi
elif [ -d "$d/lib" ] && command -v otool >/dev/null 2>&1; then
  bad=0
  while IFS= read -r f; do
    otool -L "$f" >/dev/null 2>&1 || continue
    leaks="$(otool -L "$f" | awk 'NR > 1 {print $1}' \
      | grep -vE '^(/usr/lib/|/System/|@rpath/|@loader_path/|@executable_path/)' \
      | grep -vE '^$' || true)"
    if [ -n "$leaks" ]; then
      echo "  [FAIL] absolute non-system dependency left in $f:"
      printf '%s\n' "$leaks" | sed 's/^/         /' | head -8
      bad=1
    fi
  done < <(find "$d" -type f -perm -u+x -print)
  if [ "$bad" -eq 0 ]; then
    echo "  [PASS] no absolute non-system dylib path left (rpath relocation applied)"
  else
    exit 1
  fi
fi

# 3c) 可重定位契约（2026-11-08 L2 首次全绿后的实测修复）。
# 构建容器内 php -m 有 redis/swoole、解包后却一个都不加载，根因是
# --with-config-file-scan-dir 与 extension_dir 都是构建机的绝对路径。
# 现在这是发布门禁：缺任何一层都直接 FAIL，不再降级成 WARN。
if grep -q 'PHP_INI_SCAN_DIR' "$d/bin/php" && grep -q 'ASDF_PHP_PREFIX' "$d/bin/php"; then
  echo "  [PASS] bin/php wrapper relocates PHPRC / PHP_INI_SCAN_DIR / extension_dir"
else
  echo "  [FAIL] bin/php wrapper has no relocation env — conf.d is invisible after unpack"
  exit 1
fi
if [ -f "$d/etc/conf.d/00-relocatable.ini" ] \
   && grep -q 'ASDF_PHP_PREFIX' "$d/etc/conf.d/00-relocatable.ini"; then
  echo '  [PASS] conf.d/00-relocatable.ini pins extension_dir via ${ASDF_PHP_PREFIX}'
else
  echo '  [FAIL] missing relocatable extension_dir ini'; exit 1
fi
ext_dir_line="$("$d/bin/php" -i 2>/dev/null | grep -i '^extension_dir' | head -1 || true)"
echo "  [INFO] ${ext_dir_line:-extension_dir unavailable}"
if printf '%s' "$ext_dir_line" | grep -q '/opt/php/'; then
  echo "  [FAIL] extension_dir still points at the build prefix"; exit 1
fi
if [ -f "$d/bin/php-config" ]; then
  cfg_prefix="$(cd "$d" && ./bin/php-config --prefix 2>/dev/null || true)"
  cfg_here="$(cd "$d" && pwd)"
  if [ "$cfg_prefix" = "$cfg_here" ]; then
    echo "  [PASS] php-config --prefix follows the unpack dir"
  else
    echo "  [FAIL] php-config --prefix=$cfg_prefix (expected $cfg_here)"; exit 1
  fi
fi
for f in phpize php-config pear pecl peardev; do
  if [ -f "$d/bin/$f" ] && grep -q '/opt/php/' "$d/bin/$f"; then
    echo "  [FAIL] bin/$f still hardcodes the build prefix"; exit 1
  fi
done
echo "  [PASS] no build-machine prefix left in bin/ helper scripts"

# 4) extensions declared in versions/<ver>.toml — MISSING IS A HARD FAILURE.
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
defn="$root/versions/${expected}.toml"
want_exts=()
if [ -n "$expected" ] && [ -f "$defn" ]; then
  while IFS= read -r e; do
    [ -n "$e" ] && want_exts+=("$e")
  done < <(awk '/^\[extensions\]/{s=1;next} /^\[/{s=0}
                s && /^[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*=/ {
                  sub(/[[:space:]]*=.*/, ""); print
                }' "$defn")
else
  want_exts=(redis swoole)
fi
mods="$("$d/bin/php" -m 2>/dev/null || true)"
ext_fail=0
for ext in "${want_exts[@]}"; do
  if printf '%s\n' "$mods" | grep -qi "^${ext}$"; then
    echo "  [PASS] extension $ext loaded"
  else
    echo "  [FAIL] extension $ext NOT loaded — artifact is not relocatable / conf.d broken"
    ext_fail=1
  fi
done
[ "$ext_fail" -eq 0 ] || exit 1

# 4b) 功能探针：扩展加载了不代表功能在。
# configure flag 写错的真实后果是「静默缺席」而不是报错 —— --with-mysql 在 PHP 7.0
# 被移除、--with-gd 在 8.1 改名成 --enable-gd、7.4 起 gd 的外部库开关改名为
# --with-jpeg/--with-freetype，写旧名字只会得到一行 "unrecognized options" 警告，
# 编出来照样能跑，只是图像函数全没了。这类坑只能在运行时按函数直探。
cat > "$d/.feature-probe.php" <<'PHP'
<?php
// Every one of these is off by default in this PHP version. Probing the
// function, not the flag, is the only check that cannot be fooled: configure
// happily accepts a renamed option and just builds without the extension.
$want = ['mb_strlen', 'curl_init', 'imagecreatefromjpeg', 'imagecreatefrompng',
         'imagecreatetruecolor', 'mysqli_connect', 'openssl_encrypt',
         'gzencode', 'gzdecode', 'iconv', 'bcadd', 'socket_create',
         'exif_read_data', 'pcntl_fork'];
$missing = [];
foreach ($want as $f) {
    if (!function_exists($f)) { $missing[] = $f; }
}
if (!class_exists('ZipArchive')) { $missing[] = 'ZipArchive'; }
if (!class_exists('Phar')) { $missing[] = 'Phar'; }
$drivers = class_exists('PDO') ? PDO::getAvailableDrivers() : array();
if (!in_array('mysql', $drivers)) { $missing[] = 'pdo_mysql'; }
echo $missing ? 'MISSING ' . implode(' ', $missing) : 'OK';
PHP
probe="$("$d/bin/php" "$d/.feature-probe.php" 2>&1 || true)"
rm -f "$d/.feature-probe.php"
case "$probe" in
  OK) echo "  [PASS] feature probe: mbstring curl gd(jpeg,png) mysqli pdo_mysql openssl zip zlib iconv phar bcmath sockets exif pcntl" ;;
  *)  echo "  [FAIL] feature probe: ${probe:-<no output>} — a configure flag is wrong for this version"
      echo "         cross-check with: python3 scripts/check-flags.py . --versions ${expected:-<version>}"
      exit 1 ;;
esac

# OPcache 编进制品但不默认启用（zend_extension 要显式打开，CLI 下默认也无收益）。
# 这里验的是「装得进、能加载」，不改变解包即用的默认行为。5.4 没有 opcache。
case "$expected" in
  5.4.*) ;;
  *)
    oc="$("$d/bin/php" -d zend_extension=opcache.so -r 'echo extension_loaded("Zend OPcache") ? "ok" : "no";' 2>&1 | tail -1)"
    case "$oc" in
      ok) echo "  [PASS] opcache.so present and loadable" ;;
      *)  echo "  [FAIL] opcache: ${oc:-<no output>} (expected for >=5.5, see versions/${expected:-?}.toml)"
          exit 1 ;;
    esac
    ;;
esac

# 5) build identity: proves the frozen toolchain was actually used
"$d/bin/php" -i 2>/dev/null | grep -iE 'Configure Command|OpenSSL (Library|Header) Version' | head -5 || true
echo "  [DONE] $art"
