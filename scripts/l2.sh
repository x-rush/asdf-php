#!/usr/bin/env bash
# asdf-php v2 / L2 一键链路：在 WSL 原生 ext4 目录里把 PHP 5.4.45 编出来并冒烟
#
#   cd ~/asdf-php-v2 && bash scripts/l2.sh
#
# 不要放在 /mnt/c 或 /mnt/d 下跑（drvfs 无 POSIX 执行位、9p 性能差）。
# 每一步失败即停；可重复执行（vendor.sh --write 已做幂等）。
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# 从 Windows 侧经 9p 复制过来会丢 POSIX 执行位，先补回来
chmod +x bin/install bin/list-all scripts/*.sh 2>/dev/null || true
step() { printf '\n== %s ==\n' "$*"; }
ART="php-5.4.45-linux-x86_64.tar.gz"

step "0/5 preflight"
command -v docker >/dev/null 2>&1 || { echo "docker CLI not found"; exit 1; }
docker info >/dev/null 2>&1 || {
  echo "docker daemon unreachable — start Docker Desktop / WSL integration first"
  exit 1
}
if grep -q 'REPLACE_WITH_DIGEST' build/Dockerfile.5.4; then
  echo "base digest is still a placeholder"; exit 1
fi
printf 'base: %s\n' "$(grep -m1 '^ARG BASE_IMAGE' build/Dockerfile.5.4)"

# WSL 里 ~/.docker/config.json 常是 {"credsStore":"desktop.exe"}：Docker CLI 在
# 解析任何镜像前都会调这个 helper，Desktop 的 vsock 不通时它 exit 1，构建直接
# 挂在 "error getting credentials"（docker info 不需要认证，所以 preflight 会骗过）。
# L2 只匿名拉公开镜像，用隔离的 DOCKER_CONFIG 绕开；绝不改用户的全局登录态。
if grep -q '"credsStore"' "$HOME/.docker/config.json" 2>/dev/null; then
  export DOCKER_CONFIG="$HOME/.cache/asdf-php-l2/docker"
  mkdir -p "$DOCKER_CONFIG"
  printf '{"auths":{}}\n' > "$DOCKER_CONFIG/config.json"
  printf 'docker: isolated DOCKER_CONFIG=%s (credsStore bypassed)\n' "$DOCKER_CONFIG"
fi

step "1/5 freeze sources + Debian keyring"
bash scripts/vendor.sh --write
test -s vendor/SOURCES.json
test -s keys/jessie.gpg

step "2/5 docker build (offline inputs, PHP 5.4.45)"
rm -rf out; mkdir -p out
docker build --file build/Dockerfile.5.4 --tag asdf-php-build:5.4.45 .

step "3/5 extract artifact"
cid="$(docker create asdf-php-build:5.4.45)"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker cp "$cid:/out/." out/
docker rm "$cid" >/dev/null
trap - EXIT
test -s "out/$ART"
test -s "out/$ART.sha256"
printf 'artifact: out/%s  sha256=' "$ART"
cat "out/$ART.sha256"

step "4/5 smoke"
# 宿主若装了别的 PHP，可能已设 PHPRC / PHP_INI_SCAN_DIR。wrapper 尊重用户显式
# 设置是对的，但冒烟要验的是「干净环境里解包即用」，所以这里显式清掉再跑。
env -u PHPRC -u PHP_INI_SCAN_DIR -u ASDF_PHP_PREFIX \
  bash scripts/smoke-artifact.sh "out/$ART" 5.4.45

step "5/5 done"
cat <<'TIP'
smoke is now a HARD GATE: relocation, conf.d scanning and redis/swoole
must all PASS. A WARN-free build is not enough — do not publish on WARN.
The sidecar sha256 comes from THIS build; an older artifact's hash is stale.

Next (only after the artifact passes smoke):
  1) publish the tar.gz and its .sha256 to GitHub Releases tag php-5.4.45
  2) fill manifest.json artifacts.linux-x86_64.sha256 with the sidecar value,
     set status to published, add 5.4.45 to versions.txt
  3) run the legacy CI workflow once to verify the gates
  4) mirror the base image into your own registry, then update BASE_IMAGE
     in both Dockerfile.5.4 and versions/5.4.45.toml
TIP
