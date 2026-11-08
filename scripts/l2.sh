#!/usr/bin/env bash
# asdf-php v2 / L2 一键链路：在原生 ext4 目录里把某个版本的 PHP 编出来并冒烟
#
#   bash scripts/l2.sh 7.4.33
#   bash scripts/l2.sh 5.4.45 --platform linux-arm64
#   bash scripts/l2.sh 8.1.34 --platform linux-arm64 --allow-emulation
#
# 版本、模板、base、flags、扩展全部来自 versions/<ver>.toml —— 这个脚本只做编排，
# 不再硬编码任何版本号。加一个版本的正确做法是加一份 toml，不是改这里。
#
# 不要放在 /mnt/c 或 /mnt/d 下跑（drvfs 无 POSIX 执行位、9p 性能差）。
# 每一步失败即停；可重复执行（vendor.sh 已做幂等）。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
chmod +x bin/install bin/list-all scripts/*.sh 2>/dev/null || true

step() { printf '\n== %s ==\n' "$*"; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

ver=""
platform=""
allow_emu=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform)        platform="${2:?--platform needs a value}"; shift 2 ;;
    --allow-emulation) allow_emu=1; shift ;;
    -h|--help)         sed -n '2,12p' "$0"; exit 0 ;;
    -*)                die "unknown option $1" ;;
    *)                 [ -z "$ver" ] || die "only one version at a time"; ver="$1"; shift ;;
  esac
done
[ -n "$ver" ] || die "usage: bash scripts/l2.sh <php-version> [--platform linux-x86_64|linux-arm64]"

defn="versions/$ver.toml"
[ -f "$defn" ] || die "no definition for $ver (expected $defn)"

case "$(uname -m)" in
  x86_64|amd64)  host_arch=x86_64 ;;
  aarch64|arm64) host_arch=arm64 ;;
  *)             host_arch=unknown ;;
esac
if [ -z "$platform" ]; then
  platform="linux-$host_arch"
fi
case "$platform" in
  linux-x86_64) art_arch=x86_64; docker_plat=linux/amd64 ;;
  linux-arm64)  art_arch=arm64;  docker_plat=linux/arm64 ;;
  darwin-*)     die "macOS 不走 Docker：用 bash build/macos.sh $ver" ;;
  *)            die "unsupported platform $platform" ;;
esac

read_toml() { # <dotted.key>
  python3 - "$defn" "$1" <<'PY'
import sys, tomllib
d = tomllib.load(open(sys.argv[1], "rb"))
cur = d
for part in sys.argv[2].split("."):
    if not isinstance(cur, dict) or part not in cur:
        print(""); raise SystemExit
    cur = cur[part]
print(cur if isinstance(cur, (str, int)) else "")
PY
}

generation="$(read_toml generation)"
dockerfile="$(read_toml dockerfile)"
dockerfile_generic="$(read_toml dockerfile_generic)"
[ -n "$dockerfile" ] || die "$defn has no dockerfile"

# 5.4.45 的 amd64 档案只认 x86_64（里面写死了 lib/x86_64-linux-gnu）；
# 其它平台切到多架构通用模板，是同一契约的实现，不是另一套逻辑。
if [ "$platform" != "linux-x86_64" ] && [ -n "$dockerfile_generic" ]; then
  printf 'note: %s 只覆盖 amd64，改用通用模板 %s\n' "$dockerfile" "$dockerfile_generic"
  dockerfile="$dockerfile_generic"
fi
[ -f "$dockerfile" ] || die "missing template $dockerfile"

step "0/6 preflight"
command -v docker >/dev/null 2>&1 || die "docker CLI not found"
docker info >/dev/null 2>&1 || die "docker daemon unreachable — start Docker Desktop / WSL integration first"
printf 'version : %s   generation: %s\n' "$ver" "${generation:-<none>}"
printf 'template: %s\n' "$dockerfile"
printf 'target  : %s (%s)   host: linux-%s\n' "$platform" "$docker_plat" "$host_arch"

if grep -q 'REPLACE_WITH_DIGEST' "$dockerfile"; then
  die "base digest is still a placeholder in $dockerfile — run: bash scripts/pin-base.sh <image:tag> --write"
fi
base_line="$(grep -m1 '^ARG BASE_IMAGE' "$dockerfile" || true)"
printf 'base    : %s\n' "$base_line"

if [ "$art_arch" != "$host_arch" ] && [ "$allow_emu" = 0 ]; then
  cat >&2 <<EOF
FATAL: $platform on a linux-$host_arch host needs QEMU emulation.
       Compiling PHP under emulation takes hours and hides real failures.
       Prefer a native runner (GitHub: ubuntu-24.04-arm), or pass
       --allow-emulation if you really accept the slowdown.
EOF
  exit 1
fi

# base index 必须覆盖目标平台。写错 digest 的典型症状是 docker 在拉取阶段
# 报一句含糊的错，或者更糟：静默按宿主架构构建出一个标错平台的制品。
# 平台名先归一化（`linux/arm64/v8` -> `linux/arm64`），否则目标 arm64 会被误判；
# 判定逻辑与 pin-base.sh 共用 scripts/image-platforms.sh，不写第二份。
base_ref="$(printf '%s' "$base_line" | sed 's/^ARG BASE_IMAGE=//')"
plats="$(bash scripts/image-platforms.sh "$base_ref" || true)"
if [ -n "$plats" ]; then
  case " $plats " in
    *" $docker_plat "*) printf 'base arch: %s (ok)\n' "$plats" ;;
    *) die "base index has [$plats] but target needs $docker_plat — re-pin with scripts/pin-base.sh" ;;
  esac
else
  printf 'base arch: unverified (buildx unavailable); continuing\n'
fi

# WSL 里 ~/.docker/config.json 常是 {"credsStore":"desktop.exe"}：CLI 在解析任何
# 镜像前都会调这个 helper，Desktop 的 vsock 不通时它 exit 1，构建直接挂在
# "error getting credentials"（docker info 不需要认证，所以 preflight 会骗过）。
# L2 只匿名拉公开镜像，用隔离的 DOCKER_CONFIG 绕开；绝不改用户的全局登录态。
if grep -q '"credsStore"' "$HOME/.docker/config.json" 2>/dev/null; then
  export DOCKER_CONFIG="$HOME/.cache/asdf-php-l2/docker"
  mkdir -p "$DOCKER_CONFIG"
  printf '{"auths":{}}\n' > "$DOCKER_CONFIG/config.json"
  printf 'docker  : isolated DOCKER_CONFIG=%s (credsStore bypassed)\n' "$DOCKER_CONFIG"
fi

step "1/6 freeze sources (only what $ver needs)"
bash scripts/vendor.sh --write --versions "$ver"
test -s vendor/SOURCES.json

step "2/6 expand definition -> build/.gen"
python3 scripts/gen-build-inputs.py "$ver"
test -s "build/.gen/$ver.flags"

step "3/6 docker build ($docker_plat, PHP $ver)"
rm -rf out; mkdir -p out
docker build --platform "$docker_plat" \
  --file "$dockerfile" \
  --build-arg "PHP_VERSION=$ver" \
  --build-arg "ARTIFACT_ARCH=$art_arch" \
  --tag "asdf-php-build:$ver-$art_arch" .

step "4/6 extract artifact"
cid="$(docker create --platform "$docker_plat" "asdf-php-build:$ver-$art_arch")"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker cp "$cid:/out/." out/
docker rm "$cid" >/dev/null
trap - EXIT
# 不猜文件名：5.4 的档案 Dockerfile 里名字是写死的，模板版按版本+架构拼，
# 用 glob 拿到唯一产物比在两边各写一遍命名规则可靠。
shopt -s nullglob
found=(out/php-*.tar.gz)
shopt -u nullglob
[ "${#found[@]}" -eq 1 ] || die "expected exactly one artifact in out/, found ${#found[@]}"
ART="$(basename "${found[0]}")"
test -s "out/$ART.sha256" || die "missing sidecar for $ART"
printf 'artifact: out/%s  sha256=%s\n' "$ART" "$(cat "out/$ART.sha256")"

step "5/6 smoke"
# 宿主若装了别的 PHP，可能已设 PHPRC / PHP_INI_SCAN_DIR。wrapper 尊重用户显式
# 设置是对的，但冒烟要验的是「干净环境里解包即用」，所以这里显式清掉再跑。
env -u PHPRC -u PHP_INI_SCAN_DIR -u ASDF_PHP_PREFIX \
  bash scripts/smoke-artifact.sh "out/$ART" "$ver"

step "6/6 done"
cat <<TIP
smoke is a HARD GATE: relocation, conf.d scanning, redis/swoole and the
feature probe must all PASS. A WARN-free build is not enough — do not publish.

Next (only after smoke is fully green):
  1) publish the tar.gz + .sha256 to GitHub Releases tag php-$ver
  2) fill manifest.json artifacts.$platform.sha256 with the sidecar value,
     set status to published, add $ver to versions.txt (once per version)
  3) run the CI workflow once to verify the gates on this platform
TIP
