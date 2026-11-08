#!/usr/bin/env bash
# asdf-php v2 / 把 base 镜像的多架构 index digest 解析出来并写回定义
#
#   bash scripts/pin-base.sh debian:bullseye-slim --write
#   bash scripts/pin-base.sh debian:bookworm-slim --write
#   bash scripts/pin-base.sh debian:jessie           # 只体检，不写
#
# 为什么必须是 index digest：
#   1) tag 可以被指到别的镜像上，冻结输入不能只用 tag；
#   2) 我们要 amd64 和 arm64 两个制品，只有 manifest list（index）的 digest
#      能一次锁住两个平台 —— 把 amd64 的 image digest 写进去，arm64 构建会被
#      docker 直接拒绝，或者更糟：静默跑错平台。
#
# 所以这里除了取 digest，还**强制检查 index 里同时有 linux/amd64 和 linux/arm64**。
# debian:jessie 这种老镜像不一定有 arm64，那就该在建 arm64 之前就知道，而不是
# 让 docker 在拉取阶段报一句含糊的错。
set -euo pipefail

img="${1:?usage: $0 <image:tag> [--write]}"
write=0
[ "${2:-}" = "--write" ] && write=1

command -v docker >/dev/null 2>&1 || { echo "docker CLI required" >&2; exit 1; }
docker buildx version >/dev/null 2>&1 || { echo "docker buildx required" >&2; exit 1; }

info="$(docker buildx imagetools inspect "$img" 2>&1)" || {
  echo "cannot inspect $img" >&2
  printf '%s\n' "$info" >&2
  exit 1
}

digest="$(printf '%s\n' "$info" | awk '/^Digest:/{print $2; exit}')"
[ -n "$digest" ] || { echo "no index digest in buildx output for $img" >&2; exit 1; }

# 平台列表走共用归一化：buildx 把 arm64 报成 `linux/arm64/v8`，字面匹配
# `linux/arm64` 会漏判（2026-11-08 实测误报 bullseye / bookworm 缺 arm64）。
plats="$(bash "$(dirname "${BASH_SOURCE[0]}")/image-platforms.sh" "$img" || true)"
echo "image   : $img"
echo "digest  : $digest"
echo "platform: $plats"

missing=""
for want in linux/amd64 linux/arm64; do
  case " $plats " in
    *" $want "*) ;;
    *) missing="$missing $want" ;;
  esac
done
if [ -n "$missing" ]; then
  echo "WARNING: index does not contain:$missing" >&2
  echo "         building that platform from this digest will fail; pick a base that has it" >&2
else
  echo "ok      : amd64 + arm64 both present"
fi

if [ "$write" = 1 ]; then
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  python3 - "$root" "$img" "$digest" <<'PY'
import pathlib, re, sys
root, img, digest = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
pinned = f"{img}@{digest}"
hit = 0

for p in sorted((root / "versions").glob("*.toml")):
    text = p.read_text()
    m = re.search(r'^image\s*=\s*"([^"]+)"', text, re.M)
    if not m:
        continue
    cur = m.group(1)
    ref = cur.split("@", 1)[0]
    if ref != img:
        continue
    text = text.replace(cur, pinned, 1)
    p.write_text(text)
    print(f"  pinned {p.relative_to(root)} -> {digest[:19]}…")
    hit += 1

for p in sorted((root / "build").glob("Dockerfile*")):
    text = p.read_text()
    m = re.search(r'^ARG BASE_IMAGE=(\S+)', text, re.M)
    if not m:
        continue
    cur = m.group(1)
    if cur.split("@", 1)[0] != img:
        continue
    text = text.replace(cur, pinned, 1)
    p.write_text(text)
    print(f"  pinned {p.relative_to(root)} -> {digest[:19]}…")
    hit += 1

if not hit:
    sys.exit(f"nothing referenced {img}: no definition/Dockerfile updated")
print(f"updated {hit} file(s)")
PY
else
  echo
  echo "(dry run — re-run with --write to update versions/*.toml and build/Dockerfile*)"
fi
