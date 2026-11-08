#!/bin/sh
# freetype-config 兼容层（POSIX sh）
#
# 为什么需要这一层：
#   PHP 7.2 / 7.3 的 ext/gd 仍然走 `--with-freetype-dir=DIR`，而它的 config.m4
#   里是**硬依赖**外部脚本 freetype-config —— AC_PATH_PROG 找不到就
#   `AC_MSG_ERROR([freetype-config not found.])`，configure 直接 exit 1。
#   2026-11-08 的 7.2.34 L2 实测死在 `#10 12.20 configure: error:
#   freetype-config not found.`（7.3.33 是同一段 m4，同一种死法）。
#   而 Debian bullseye 的 libfreetype6-dev 已经不再安装这个脚本
#   （freetype 2.10 起上游停止安装，官方建议改用 pkg-config）：
#   g1 用的 jessie 有、g2 用的 bullseye 没有，所以只有 g2 需要补。
#
# 实现取舍：
#   只翻译 PHP 真正调用的四个开关，数值全部转交 pkg-config 的 freetype2.pc，
#   不自己拼 -I/-L。写死 /usr/include/freetype2 在 amd64 上能过，到 arm64 的
#   multiarch 布局就可能错位 —— 这类「本机绿了、跨架构红」的坑不值得踩第二次。
set -eu

for arg in "$@"; do
  case "$arg" in
    --cflags)             exec pkg-config --cflags freetype2 ;;
    --libs)               exec pkg-config --libs freetype2 ;;
    --version|--ftversion) exec pkg-config --modversion freetype2 ;;
    --prefix)             exec pkg-config --variable=prefix freetype2 ;;
  esac
done

echo "freetype-config (asdf-php shim): unsupported option: $*" >&2
echo "supported: --cflags --libs --version --ftversion --prefix" >&2
exit 1
