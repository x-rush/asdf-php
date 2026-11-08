#!/bin/sh
# apt-install — 装构建依赖，不管这个 suite 现在还剩在哪个镜像上。
#
# 为什么需要它（2026-11-08 实测，WSL / bullseye / PHP 7.4.33）：
#   活源失败 → 切 archive.debian.org → Fastly 边缘到国内链路抖，
#   "Fetched 67.7 MB in 8min 8s (139 kB/s)" 之后 3 个包 Connection failed，
#   apt 以 exit 100 退出，整层重来，已经下完的 67 MB 又扔一次。
#   而 apt 本身完全支持续传与重试 —— 只是没人给它第二次机会。
#
# 这个脚本给的是三次机会，且每一步都留着 /var/cache/apt/archives：
#   1. Acquire::Retries=10 + 关 HTTP pipelining + 强制 IPv4：单包断连自愈；
#   2. install 失败立刻 dpkg --configure -a + --fix-missing 重跑，apt 从
#      partial/ 续传，只补缺的那几个包；
#   3. 换源重试：活源（仅未 EOL 的 suite）→ 国内归档镜像 → archive.debian.org，
#      换源不清缓存，已下完的包全部复用。
#
# 关于「活源为什么常常不可用」：bullseye 已经 EOL，deb.debian.org 上它的
# security 索引还在发布十年前那样的 Release，但索引里点名的那些文件（perl
# 5.32.1-4+deb11u5、gcc-10 10.2.1-6、libicu67 …）已从 pool 里清走。于是
# apt-get update 全部成功、apt-get install 逐个 404 —— 看起来像网络抖动，
# 实际是这个源对它自己的 suite 已经不完整了。EOL 的 suite 因此跳过活源。
#
# 国内归档镜像排在 archive.debian.org 前面，是被实测数据推着改的：archive 走
# Fastly，从国内单向只有 139 kB/s（67.7 MB 要 8 分钟）且会中途断连，而阿里云 /
# 南大同步的是同一份归档、包哈希一致，实测 235 个包 180 秒装完。代价是非中国区
# 用户要多付一两次连接超时（各 30 秒）——archive.debian.org 仍在链尾兜底，
# 任何地区都不会因此失去可用源。顺序可被 APT_MIRROR_MAIN 完全覆盖。
#
# 源候选都写成「完整 sources.list」而不是逐条拼：某个 suite 被整体撤走时，
# 一条 404 就会让 apt-get update 整体失败，必须先剔掉整条源而不是修补它。
#
# 归档镜像的验证策略：先用真签名（Release 有效期内）跑一遍；只有签名/有效期
# 这一关过不去时才退到 [trusted=yes]。jessie 的 Release 签名早已过期，所以它
# 必然走到第二档 —— 这不是「放宽校验」，而是 EOL suite 的唯一可行路径；
# 制品的可复现性由 base digest + vendor/ 的 sha256 锁定，不依赖 apt 签名。
#
# 用法: apt-install.sh <dist> <package>...
#   APT_MIRROR_MAIN / APT_MIRROR_SEC 环境变量可插队一个自定义源（内网镜像、
#   代理网关）。Dockerfile 里对应 --build-arg APT_MIRROR_MAIN=...。
set -eu

DIST="${1:?usage: apt-install.sh <dist> <package>...}"
shift
[ "$#" -gt 0 ] || { echo "apt-install: at least one package is required" >&2; exit 2; }

export DEBIAN_FRONTEND=noninteractive

# Debian 10 及更早的 security suite 叫 <release>/updates，11 起改叫 <release>-security。
case "$DIST" in
  jessie|stretch|buster) SEC_SUITE="$DIST/updates" ;;
  *)                     SEC_SUITE="$DIST-security" ;;
esac

log() { printf 'apt-install: %s\n' "$*"; }

# 归档里的 jessie/stretch Release 签名密钥早已过期，apt 会因为「-y 但仓库未通过
# 认证」直接拒绝（E: There are problems and -y was used without --force-yes），
# 真签名那一档必然失败 —— 实测白等 21 秒只为看三条同样的错误。这两个 suite 直接
# 从 [trusted=yes] 起跑；buster 之后密钥仍有效，保持先验签名。
# 必须在 try_source 之前定好：APT_MIRROR_MAIN 那次插队调用也要用它（set -u 下
# 未定义会直接退出，而那条路正是用户网络不通时唯一能走的路）。
case "$DIST" in
  jessie|stretch) TRUST_ORDER="1 0" ;;
  *)              TRUST_ORDER="0 1" ;;
esac

# 两个路径可注入，只为了让 scripts/test.sh 能在普通用户下把整条候选链跑一遍
# （换源顺序、断点续传这类行为只在网络坏的时候才显形，而那时最不该靠肉眼）。
# 生产构建不设这两个变量，就是 /etc/apt 与 /var/lib/apt/lists。
APT_ETC="${APT_ETC:-/etc/apt}"
APT_LISTS="${APT_LISTS:-/var/lib/apt/lists}"
mkdir -p "$APT_ETC/apt.conf.d"
clean_lists() { rm -rf "$APT_LISTS"/* 2>/dev/null || true; }

printf '%s\n' \
  'Acquire::Check-Valid-Until "false";' \
  'Acquire::Retries "10";' \
  'Acquire::http::Timeout "30";' \
  'Acquire::https::Timeout "30";' \
  'Acquire::http::Pipeline-Depth "0";' \
  'Acquire::ForceIPv4 "true";' \
  'DPkg::Options { "--force-confdef"; "--force-confold"; };' \
  > "$APT_ETC/apt.conf.d/99-apt-install"

write_list() {
  base_main="$1"; base_sec="$2"; trusted="$3"
  if [ "$trusted" = 1 ]; then pre='[trusted=yes] '; else pre=''; fi
  printf '%s\n' \
    "deb $pre$base_main $DIST main" \
    "deb $pre$base_sec $SEC_SUITE main" \
    > "$APT_ETC/sources.list"
}

# 所有 apt 调用都 </dev/null：外层可能正用 heredoc/管道喂候选列表，apt 读走
# stdin 会吃掉后面的候选。
install_pkgs() {
  apt-get install -y --no-install-recommends "$@" < /dev/null && return 0
  log "install interrupted; dpkg --configure -a, then resume with --fix-missing"
  dpkg --configure -a > /dev/null 2>&1 || true
  apt-get install -y --no-install-recommends --fix-missing "$@" < /dev/null && return 0
  dpkg --configure -a > /dev/null 2>&1 || true
  apt-get --fix-broken install -y < /dev/null || true
  apt-get install -y --no-install-recommends --fix-missing "$@" < /dev/null && return 0
  return 1
}

try_source() {
  label="$1"; base_main="$2"; base_sec="$3"; shift 3
  for trusted in $TRUST_ORDER; do
    write_list "$base_main" "$base_sec" "$trusted"
    if [ "$trusted" = 1 ]; then
      log "trying $label ($base_main) — signature check off"
    else
      log "trying $label ($base_main)"
    fi
    if apt-get update < /dev/null > /dev/null; then
      if install_pkgs "$@"; then
        log "ok via $label"
        return 0
      fi
    else
      log "$label: apt-get update did not succeed (suite gone, or network)"
    fi
  done
  return 1
}

# 候选链放在函数里，而不是裸循环：循环体要用固定数量的位置参数给 try_source，
# 而包列表也在 $@ 上，写在一层就够呛，两层必错。
main() {
  if [ -n "${APT_MIRROR_MAIN:-}" ]; then
    log "APT_MIRROR_MAIN override in use: $APT_MIRROR_MAIN"
    if try_source override "$APT_MIRROR_MAIN" "${APT_MIRROR_SEC:-$APT_MIRROR_MAIN}" "$@"; then
      clean_lists
      log "done: $DIST"
      return 0
    fi
  fi

  # EOL 的 suite 直接跳过活源。理由不是「它慢」，是它**不可用**：
  # deb.debian.org 上的 bullseye-security 索引到现在还指向 perl 5.32.1-4+deb11u5
  # 之类的旧版，而 pool 里那些文件早已被清走 —— update 一律成功、install 一律
  # 404（2026-11-08 实测，47 个包里 4 个 404）。把这个源放在第一位等于每次构建
  # 先白下 70 MB 再失败。EOL 之后唯一完整的是归档镜像。
  case "$DIST" in
    jessie|stretch|buster|bullseye)
      log "$DIST is end-of-life: skipping deb.debian.org (its pool no longer matches its own security index)"
      candidates="\
mirrors.aliyun.com|http://mirrors.aliyun.com/debian-archive/debian|http://mirrors.aliyun.com/debian-archive/debian-security \
nju|http://mirror.nju.edu.cn/debian-archive/debian|http://mirror.nju.edu.cn/debian-archive/debian-security \
archive.debian.org|http://archive.debian.org/debian|http://archive.debian.org/debian-security"
      ;;
    *)
      candidates="\
live|http://deb.debian.org/debian|http://deb.debian.org/debian-security \
mirrors.aliyun.com|http://mirrors.aliyun.com/debian-archive/debian|http://mirrors.aliyun.com/debian-archive/debian-security \
nju|http://mirror.nju.edu.cn/debian-archive/debian|http://mirror.nju.edu.cn/debian-archive/debian-security \
archive.debian.org|http://archive.debian.org/debian|http://archive.debian.org/debian-security"
      ;;
  esac

  for spec in $candidates; do
    label=${spec%%|*}
    rest=${spec#*|}
    base_main=${rest%%|*}
    base_sec=${rest#*|}
    if try_source "$label" "$base_main" "$base_sec" "$@"; then
      clean_lists
      log "done: $DIST"
      return 0
    fi
  done
  return 1
}

if main "$@"; then
  exit 0
fi

echo "apt-install: every source candidate failed for $DIST." >&2
echo "             If this machine reaches Debian through a proxy or an internal" >&2
echo "             mirror, pass --build-arg APT_MIRROR_MAIN=<base-url> (and" >&2
echo "             optionally APT_MIRROR_SEC=<base-url>) and re-run." >&2
exit 1
