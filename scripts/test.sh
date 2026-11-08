#!/usr/bin/env bash
# asdf-php v2 / L0 + L1 contract tests
#
#   bash scripts/test.sh
#
# No Docker, no network egress, no real PHP source needed. Spins up a throwaway
# localhost HTTP server that pretends to be the GitHub Releases artifact repo,
# so the whole thin-plugin contract (download -> sha256 -> unpack -> self-check)
# is exercised end to end. Run it on WSL/Linux/macOS or Git Bash.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
srv_pid=""
cleanup_tmp() {
  if [ -n "$srv_pid" ]; then kill "$srv_pid" 2>/dev/null || true; fi
  # On MinGW, mktemp returns a Windows-style path ("C:/...") which desktop
  # safe-delete guards reject. Remove through Python instead.
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$tmp" 2>/dev/null || true
}
trap cleanup_tmp EXIT

# GNU tar reads a "C:/..." argument as a remote tape host on MinGW/MSYS.
# An exported bash function is inherited by bin/install (a child bash), and
# avoids putting a Windows path with a colon into PATH (that breaks PATH).
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    tar() { command tar --force-local "$@"; }
    export -f tar
    printf '  [INFO] %s: tar --force-local enabled for this test tree\n' "$(uname -s)"
    ;;
esac

n_pass=0 n_fail=0
pass() { printf '  [PASS] %s\n' "$*"; n_pass=$((n_pass + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; n_fail=$((n_fail + 1)); }
skip() { printf '  [SKIP] %s\n' "$*"; }

echo "== asdf-php v2 / L0 static contract =="

if bash -n "$root/bin/install" "$root/bin/list-all" "$root/scripts/vendor.sh" \
        "$root/scripts/relocate.sh" "$root/scripts/smoke-artifact.sh" 2>"$tmp/n.err"; then
  pass "T1 bash -n on all 5 shell scripts"
else
  fail "T1 syntax: $(cat "$tmp/n.err")"
fi

if python3 - "$root" <<'PY' 2>"$tmp/json.err"
import json, re, sys
root = sys.argv[1]
m = json.load(open(root + "/manifest.json"))
for v in m["versions"]:
    for arch, a in v["artifacts"].items():
        s = a["sha256"]
        assert s is None or re.fullmatch(r"[0-9a-f]{64}", s), (v["version"], arch, s)
        if s is None:
            assert a.get("status") == "not_built"
print("ok")
PY
then
  pass "T2 manifest.json parses; sha256 is null or 64-hex, never a placeholder"
else
  fail "T2 manifest: $(cat "$tmp/json.err")"
fi

if python3 - "$root" <<'PY' 2>"$tmp/vers.err"
import json, sys
root = sys.argv[1]
m = json.load(open(root + "/manifest.json"))
published = {v["version"] for v in m["versions"]
             if any(a.get("status") == "published" for a in v["artifacts"].values())}
listed = {ln.split()[0] for ln in open(root + "/versions.txt")
          if ln.strip() and not ln.lstrip().startswith("#")}
assert published == listed, (published, listed)
print("ok")
PY
then
  pass "T3 versions.txt lists exactly the published artifacts (both empty is valid)"
else
  fail "T3 versions.txt: $(cat "$tmp/vers.err")"
fi

# T3b: SSL isolation contract, learned the hard way during L2 (2026-11-08).
# jessie's libpq.so needs Debian's versioned SSL_*@OPENSSL_1.0.0 symbols; the
# vendored OpenSSL 1.0.2u lacks a version script, so linking -lpq alongside
# --with-openssl=<prefix> fails at make time with 40+ undefined references.
# libcurl was pulled off the same cliff by switching to the GnuTLS backend.
# Comment lines are stripped first so the rationale can be documented inline.
if sed 's/^[[:space:]]*#.*$//' "$root/build/Dockerfile.5.4" "$root/versions/5.4.45.toml" \
     | grep -qE -- '--with-(pdo-)?pgsql|libpq-dev'; then
  fail "T3b legacy build inputs re-introduced libpq/pgsql (breaks SSL symbol isolation)"
else
  pass "T3b SSL isolation: no libpq/pgsql in frozen build inputs"
fi

# T3c: support scope must stay frozen and internally consistent (frozen 2026-11-08).
# A "planned" version is NOT a published one; guard against scope drift and
# against somebody silently adding a version outside the agreed closed set.
if python3 - "$root" <<'PY' 2>"$tmp/matrix.err"
import json, re, sys
root = sys.argv[1]
m = json.load(open(root + "/manifest.json"))
sm = m["support_matrix"]
scope = sm["scope"]["legacy_frozen"]
assert len(scope) == 7 == len(set(scope)), scope
assert {v["version"] for v in m["versions"]} <= set(scope)
assert set(m["planned_legacy"]) == set(scope) - {v["version"] for v in m["versions"]}
assert sm["scope"]["current_from"] == m["current_channel"]["from"] == "8.2"
pinned = [p for g in sm["generations"] for p in g["php"]
          if re.fullmatch(r"\d+\.\d+\.\d+", p)]
assert set(pinned) == set(scope), (pinned, scope)
assert sm["template_count"] == len(sm["generations"]) == 3
print("ok")
PY
then
  pass "T3c support scope: 7 EOL last releases frozen, 3 generations, current from 8.2"
else
  fail "T3c support_matrix drift: $(tail -2 "$tmp/matrix.err")"
fi

# T3d: 制品可重定位契约（2026-11-08 L2 首次全绿后修复）。只带 soname 不够：
# conf.d 扫描目录和 extension_dir 都是编译期绝对路径，解包后扩展全部不加载。
# 这条静态门禁防止后人把 relocate 逻辑删掉、或把扩展检查降级回 WARN。
if grep -q 'PHP_INI_SCAN_DIR' "$root/scripts/relocate.sh" \
   && grep -q 'ASDF_PHP_PREFIX' "$root/scripts/relocate.sh" \
   && grep -q '00-relocatable.ini' "$root/scripts/relocate.sh" \
   && grep -q 'relocate.sh' "$root/build/Dockerfile.5.4" \
   && grep -q 'php-config --prefix' "$root/build/Dockerfile.5.4" \
   && grep -q '\[FAIL\] extension' "$root/scripts/smoke-artifact.sh"; then
  pass "T3d relocation contract: ini scan dir + extension_dir + hard extension gate"
else
  fail "T3d relocation contract missing / weakened"
fi

# T3e: the platform gate in bin/install, manifest.json -> platforms.published
# and the README table must agree. Three copies of one fact is exactly how a
# "supported platform" ends up shipping a 404.
gate="$(sed -n 's/^SUPPORTED="\(.*\)"$/\1/p' "$root/bin/install" | head -1)"
mpub="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1],encoding="utf-8"))["platforms"]["published"]))' "$root/manifest.json" 2>/dev/null || echo '__ERR__')"
rdpub="$(sed -n 's/^| *\([a-z0-9_]*-[a-z0-9_]*\) *| *supported *|$/\1/p' "$root/README.md" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
if [ -z "$gate" ]; then
  fail "T3e bin/install has no SUPPORTED platform gate"
elif [ "$mpub" = "__ERR__" ]; then
  fail "T3e manifest.json has no platforms.published"
elif [ "$gate" != "$mpub" ]; then
  fail "T3e platform drift: bin/install [$gate] != manifest [$mpub]"
elif [ "$gate" != "$rdpub" ]; then
  fail "T3e platform drift: bin/install [$gate] != README supported rows [$rdpub]"
else
  pass "T3e platform gate == manifest.published == README table ($gate)"
fi

echo "== asdf-php v2 / L1 artifact-repo contract =="
# The fake release server serves the artifact name bin/install would request on
# a SUPPORTED host. It is pinned to linux-x86_64 rather than derived from the
# host running this suite, because bin/install now applies a platform gate and
# Git Bash reports MINGW* — deriving from the real uname would produce a name
# the plugin never asks for.
ver="9.9.9"
name="php-${ver}-linux-x86_64.tar.gz"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else return 1
  fi
}

make_artifact() { # <dest> <with_bin:1|0>
  local dest="$1" with_bin="$2" stage="$tmp/stage"
  python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1], ignore_errors=True)' "$stage"
  mkdir -p "$stage/bin"
  if [ "$with_bin" = 1 ]; then
    printf '%s\n' '#!/usr/bin/env sh' 'echo "PHP 9.9.9 (v2 test artifact)"' > "$stage/bin/php"
    chmod +x "$stage/bin/php"
  else
    printf '%s\n' 'deliberately missing bin/php' > "$stage/README"
  fi
  tar -czf "$dest" -C "$stage" .
}

repo="$tmp/repo/php-$ver"
mkdir -p "$repo"
printf '%s\n' '# published versions' '5.4.45' '' '# comment' '8.5.12' > "$tmp/repo/versions.txt"
make_artifact "$repo/$name" 1
sha256_of "$repo/$name" > "$repo/$name.sha256"

port="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$tmp/repo" >"$tmp/http.log" 2>&1 &
srv_pid=$!
if ! curl -fsS --retry 20 --retry-delay 0 --retry-connrefused \
        "http://127.0.0.1:$port/versions.txt" -o /dev/null 2>/dev/null; then
  echo "local test server failed to start; see $tmp/http.log" >&2
  cat "$tmp/http.log" >&2
  exit 1
fi
pass "T0 local artifact repo up on 127.0.0.1:$port (fake version $ver / linux-x86_64)"

# T4: remote unreachable -> local versions.txt fallback, must exit 0 and mirror
# the local published list exactly. Originally the local list was empty; after
# 5.4.45 was published it is not, so never hardcode "empty output" here.
if out="$(ASDF_PHP_VERSIONS_URL='http://127.0.0.1:1/nope' bash "$root/bin/list-all" 2>/dev/null)"; then
  want="$(awk '!/^[[:space:]]*#/ && NF {print $1}' "$root/versions.txt")"
  if [ "$out" = "$want" ]; then
    pass "T4 remote down -> local versions.txt fallback (exit 0, exact list)"
  else
    fail "T4 fallback list mismatch: got [$out], want [$want]"
  fi
else
  fail "T4 list-all should not fail when the remote is down"
fi

# T5: comment/blank filtering through the remote path
out="$(ASDF_PHP_VERSIONS_URL="http://127.0.0.1:$port/versions.txt" bash "$root/bin/list-all" 2>/dev/null)"
if [ "$out" = "$(printf '5.4.45\n8.5.12')" ]; then pass "T5 list-all strips comments/blank lines"
else fail "T5 unexpected list: [$out]"; fi

if ! command -v sha256sum >/dev/null 2>&1; then
  skip "T6-T8: bin/install requires sha256sum; run these on Linux/WSL"
else
  # bin/install now refuses platforms that have no published artifact. These
  # tests exercise the download path, so hand them a fake uname that reports
  # the one supported platform — production code stays unaware of tests.
  # cygpath -u keeps MinGW paths out of PATH (a colon in PATH is fatal).
  mkdir -p "$tmp/fakebin"
  cat > "$tmp/fakebin/uname" <<'FAKE_UNAME'
#!/bin/sh
case "${1:-}" in
  -m) echo x86_64 ;;
  *)  echo Linux ;;
esac
FAKE_UNAME
  chmod +x "$tmp/fakebin/uname"
  fakebin="$tmp/fakebin"
  if command -v cygpath >/dev/null 2>&1; then fakebin="$(cygpath -u "$tmp/fakebin")"; fi

  # Pass a RELATIVE install path: on MinGW, GNU tar cannot handle a Windows
  # drive-letter path in -C even with --force-local.
  run_install() { # <relative install path under $tmp>
    ( cd "$tmp" &&
      PATH="$fakebin:$PATH" \
      ASDF_INSTALL_VERSION="$ver" \
      ASDF_INSTALL_PATH="$1" \
      ASDF_PHP_RELEASE_BASE="http://127.0.0.1:$port" \
        bash "$root/bin/install" )
  }

  # T6: happy path
  if run_install "i_ok" >"$tmp/ok.out" 2>&1 && [ -x "$tmp/i_ok/bin/php" ] \
     && "$tmp/i_ok/bin/php" -v 2>/dev/null | grep -q 'PHP 9.9.9'; then
    pass "T6 valid artifact -> download, sha256 verify, unpack, bin/php self-check"
  else
    fail "T6 install: $(tail -3 "$tmp/ok.out")"
  fi

  # T7: tampered checksum must abort before creating anything
  printf '%064d\n' 0 > "$repo/$name.sha256"
  if run_install "i_bad" >"$tmp/bad.out" 2>&1; then
    fail "T7 tampered sha256 should have failed but succeeded"
  elif grep -q 'sha256 mismatch' "$tmp/bad.out"; then
    pass "T7 tampered sha256 -> refused with mismatch (no silent install)"
  else
    fail "T7 failed for the wrong reason: $(tail -2 "$tmp/bad.out")"
  fi

  # T8: artifact without bin/php must abort
  sha256_of "$repo/$name" > "$repo/$name.sha256"
  make_artifact "$repo/$name" 0
  sha256_of "$repo/$name" > "$repo/$name.sha256"
  if run_install "i_nobin" >"$tmp/nobin.out" 2>&1; then
    fail "T8 artifact without bin/php should have failed but succeeded"
  elif grep -q 'artifact has no bin/php' "$tmp/nobin.out"; then
    pass "T8 corrupt artifact -> refused with explicit message"
  else
    fail "T8 failed for the wrong reason: $(tail -2 "$tmp/nobin.out")"
  fi

  # T8b: a platform with no published artifact must be refused BEFORE the
  # download, with a message naming what is actually available. This is what
  # turns a bare HTTP 404 into something a user can act on.
  mkdir -p "$tmp/fakebin-darwin"
  cat > "$tmp/fakebin-darwin/uname" <<'FAKE_DARWIN'
#!/bin/sh
case "${1:-}" in
  -m) echo arm64 ;;
  *)  echo Darwin ;;
esac
FAKE_DARWIN
  chmod +x "$tmp/fakebin-darwin/uname"
  fbd="$tmp/fakebin-darwin"
  if command -v cygpath >/dev/null 2>&1; then fbd="$(cygpath -u "$tmp/fakebin-darwin")"; fi

  if ( cd "$tmp" && PATH="$fbd:$PATH" \
        ASDF_INSTALL_VERSION="$ver" ASDF_INSTALL_PATH="i_plat" \
        ASDF_PHP_RELEASE_BASE="http://127.0.0.1:$port" \
          bash "$root/bin/install" ) >"$tmp/plat.out" 2>&1; then
    fail "T8b darwin-arm64 should have been refused but the install succeeded"
  elif grep -q 'no prebuilt artifact for darwin-arm64' "$tmp/plat.out" \
       && grep -q 'currently published: linux-x86_64' "$tmp/plat.out"; then
    pass "T8b unsupported platform -> refused before download, names what exists"
  else
    fail "T8b wrong rejection reason: $(tail -2 "$tmp/plat.out")"
  fi
  if [ -e "$tmp/i_plat" ]; then
    fail "T8b refusal must not create the install path"
  else
    pass "T8b refusal left no partial install directory"
  fi
fi

echo "== asdf-php v2 / L1' relocation unit test =="
# 不依赖 Docker：造一棵假的 PHP prefix 树，跑真正的 relocate.sh，逐项验证
# 「解压到陌生路径后 ini / 扩展 / 配套脚本还能用」这件事的结构性前提。
fake="$tmp/fake-php"
mkdir -p "$fake/bin" "$fake/lib" "$fake/etc/conf.d" \
         "$fake/lib/php/extensions/no-debug-non-zts-20100525"
: > "$fake/lib/php/extensions/no-debug-non-zts-20100525/redis.so"
printf 'extension=redis.so\n' > "$fake/etc/conf.d/redis.ini"
printf '#!/bin/sh\necho "PHP 5.4.45 (cli)"\n' > "$fake/bin/php"
printf '#!/bin/sh\necho "PHP 5.4.45 (cgi)"\n' > "$fake/bin/php-cgi"
cat > "$fake/bin/phpize" <<'FAKE'
#!/bin/sh
prefix='__PREFIX__'
datarootdir='__PREFIX__/php'
echo "$prefix"
FAKE
cat > "$fake/bin/php-config" <<'FAKE'
#! /bin/sh
prefix="__PREFIX__"
datarootdir="__PREFIX__/php"
ldflags=" -L/opt/toolchain/openssl-1.0.2u/lib/x86_64-linux-gnu"
extension_dir='__PREFIX__/lib/php/extensions/no-debug-non-zts-20100525'
configure_options=" '--prefix=__PREFIX__'"
case "$1" in --prefix) echo "$prefix";; *) echo ok;; esac
FAKE
cat > "$fake/bin/pear" <<'FAKE'
#!/bin/sh

PHP="__PREFIX__/bin/php"
INCDIR="__PREFIX__/lib/php"
exec $PHP $INCDIR/pearcmd.php "$@"
FAKE
printf '#!/opt/php/5.4.45/bin/php\n<?php echo "phar";\n' > "$fake/bin/phar.phar"
ln -s /opt/php/5.4.45/bin/phar.phar "$fake/bin/phar" 2>/dev/null || true
chmod +x "$fake/bin/php" "$fake/bin/php-cgi" "$fake/bin/phpize" \
         "$fake/bin/php-config" "$fake/bin/pear" "$fake/bin/phar.phar"
fake_abs="$(cd "$fake" && pwd)"
sed -i "s#__PREFIX__#$fake_abs#g" \
  "$fake/bin/phpize" "$fake/bin/php-config" "$fake/bin/pear"

if sh "$root/scripts/relocate.sh" "$fake_abs" >"$tmp/reloc.out" 2>&1; then
  pass "T9a relocate.sh runs clean on a fake prefix tree"
else
  fail "T9a relocate.sh: $(tail -3 "$tmp/reloc.out")"
fi
if grep -q 'PHP_INI_SCAN_DIR' "$fake/bin/php" \
   && grep -q 'ASDF_PHP_PREFIX' "$fake/bin/php" \
   && [ -x "$fake/libexec/php.bin" ] \
   && "$fake/bin/php" -v 2>/dev/null | grep -q 'PHP 5.4.45'; then
  pass "T9b wrapper exports relocation env and still execs the real binary"
else
  fail "T9b wrapper broken: $(head -3 "$fake/bin/php")"
fi
if grep -q 'extension_dir=${ASDF_PHP_PREFIX}/lib/php/extensions/' \
        "$fake/etc/conf.d/00-relocatable.ini"; then
  pass "T9c conf.d/00-relocatable.ini relocates extension_dir via ini interpolation"
else
  fail "T9c missing/invalid 00-relocatable.ini"
fi
cfg_prefix="$(cd "$fake" && ./bin/php-config --prefix 2>/dev/null || true)"
if [ "$cfg_prefix" = "$fake_abs" ] \
   && ! grep -q "$fake_abs" "$fake/bin/phpize" \
   && ! grep -q "$fake_abs" "$fake/bin/php-config" \
   && ! grep -q "$fake_abs" "$fake/bin/pear" \
   && grep -q '^here=' "$fake/bin/pear"; then
  pass "T9d phpize / php-config / pear follow the unpack dir, no hardcoded prefix"
else
  fail "T9d helper scripts still hardcode the build prefix (cfg=$cfg_prefix)"
fi
if [ -x "$fake/libexec/phar.phar" ] \
   && grep -q 'libexec/phar.phar' "$fake/bin/phar.phar" \
   && ! grep -q '/opt/php/' "$fake/bin/phar.phar"; then
  pass "T9e phar.phar shebang is replaced by a relocatable sh wrapper"
else
  fail "T9e phar relocation incomplete"
fi

echo "== gating state (informational, not a failure) =="
if grep -q 'REPLACE_WITH_DIGEST' "$root/build/Dockerfile.5.4"; then
  skip "L2 blocked by design: base digest placeholder is unresolved"
else
  pass "base digest resolved; L2 docker build is unblocked"
fi
if [ -f "$root/vendor/SOURCES.json" ]; then
  pass "vendor/SOURCES.json present"
else
  skip "L2 blocked by design: run scripts/vendor.sh --write first"
fi

printf '\n== RESULT: %d passed, %d failed ==\n' "$n_pass" "$n_fail"
[ "$n_fail" -eq 0 ] || exit 1
