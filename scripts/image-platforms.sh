#!/usr/bin/env bash
# 打印某个镜像 index 里可构建的平台列表（归一化、去重、去 attestation），
# 供 pin-base.sh 与 l2.sh 共用同一套判定 —— 两处各写一份比较逻辑，迟早分叉。
#
#   bash scripts/image-platforms.sh debian:bullseye-slim
#   -> linux/386 linux/amd64 linux/arm/v7 linux/arm64
#
# 为什么要归一化：buildx 的 Platform 行带变体后缀，arm64 写作 `linux/arm64/v8`，
# amd64 可能写作 `linux/amd64/v2`。按字面匹配 `linux/arm64` 会漏判 ——
# 2026-11-08 实测 bullseye / bookworm 两个 index 明明都覆盖 arm64，却被报成
# "index does not contain: linux/arm64"，把真警告变成天天出现的噪音；
# 更糟的是这种噪音会让真正缺 arm64 的 base 也一起被无视。
# 同时丢掉 `unknown/unknown`：那是 attestation manifest，不是能构建的平台。
set -euo pipefail

ref="${1:?usage: $0 <image[:tag][@digest]>}"

command -v docker >/dev/null 2>&1 || exit 1

docker buildx imagetools inspect "$ref" 2>/dev/null \
  | awk '/^[[:space:]]*Platform:/{print $2}' \
  | awk -F/ '
      $1 == "unknown" { next }
      NF >= 3 && ($2 == "arm64" || $2 == "amd64" || $2 == "riscv64" || $2 == "loong64" || $2 == "mips64le") {
        print $1 "/" $2; next
      }
      { print }
    ' \
  | sort -u \
  | tr '\n' ' ' \
  | sed 's/ *$//'
