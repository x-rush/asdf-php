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
        "$root/scripts/relocate.sh" "$root/scripts/smoke-artifact.sh" \
        "$root/scripts/pack-artifact.sh" "$root/scripts/pin-base.sh" \
        "$root/scripts/image-platforms.sh" \
        "$root/scripts/l2.sh" "$root/build/macos.sh" 2>"$tmp/n.err"; then
  pass "T1 bash -n on all 10 shell scripts"
else
  fail "T1 syntax: $(cat "$tmp/n.err")"
fi

if python3 -m py_compile "$root/scripts/gen-build-inputs.py" "$root/scripts/vendor-ledger.py" \
        "$root/scripts/fill-placeholders.py" "$root/scripts/verify-hashes.py" \
        "$root/scripts/check-flags.py" 2>"$tmp/py.err"; then
  pass "T1b build helper scripts compile"
else
  fail "T1b python syntax: $(cat "$tmp/py.err")"
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
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
m = json.load(open(root / "manifest.json"))
published = {v["version"] for v in m["versions"]
             if any(a.get("status") == "published" for a in v["artifacts"].values())}
listed = [ln.split()[0] for ln in open(root / "versions.txt")
          if ln.strip() and not ln.lstrip().startswith("#")]
listed_set = set(listed)

# versions.txt drives `asdf list-all`, so it answers "what can I install",
# which is a superset of "what is published": a version that compiles is
# installable through scripts/l2.sh --install even with zero releases. The
# old assertion demanded equality, which meant a working local build could
# never show up in list-all. Two separate invariants replace it.
missing = published - listed_set
assert not missing, f"published but missing from versions.txt: {sorted(missing)}"
undefined = [v for v in listed if not (root / "versions" / f"{v}.toml").is_file()]
assert not undefined, f"listed in versions.txt with no definition toml: {undefined}"
assert len(listed) == len(listed_set), f"duplicate versions.txt entries: {listed}"
print("ok")
PY
then
  pass "T3 versions.txt covers every published version AND every line has a definition"
else
  fail "T3 versions.txt: $(cat "$tmp/vers.err")"
fi

# T3b: SSL isolation contract, learned the hard way during L2 (2026-11-08).
# jessie's libpq.so needs Debian's versioned SSL_*@OPENSSL_1.0.0 symbols; the
# vendored OpenSSL 1.0.2u lacks a version script, so linking -lpq alongside
# --with-openssl=<prefix> fails at make time with 40+ undefined references.
# libcurl was pulled off the same cliff by switching to the GnuTLS backend.
# Applies to every G1 build (the archival 5.4 file and the multi-arch template).
# Comment lines are stripped first so the rationale can be documented inline.
if sed 's/^[[:space:]]*#.*$//' "$root/build/Dockerfile.5.4" "$root/build/Dockerfile.g1" \
        "$root/versions/5.4.45.toml" "$root/versions/5.6.40.toml" \
     | grep -qE -- '--with-(pdo-)?pgsql|libpq-dev'; then
  fail "T3b legacy build inputs re-introduced libpq/pgsql (breaks SSL symbol isolation)"
else
  pass "T3b SSL isolation: no libpq/pgsql in any G1 build input"
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

# T3f/T3g/T3i: 全矩阵脚手架的结构一致性。版本一多，"某个版本没有定义文件"
# 或"模板名写错了"这类问题不会自己冒出来，只会在 CI 里浪费一次构建才暴露。
if python3 - "$root" <<'PY' 2>"$tmp/matrix2.err"
import json, pathlib, sys, tomllib
root = pathlib.Path(sys.argv[1])
m = json.load(open(root / "manifest.json"))
scope = m["support_matrix"]["scope"]["legacy_frozen"]
gens = {g["id"] for g in m["support_matrix"]["generations"]}

for ver in scope:
    p = root / "versions" / f"{ver}.toml"
    assert p.is_file(), f"missing definition {p.name}"
    d = tomllib.load(p.open("rb"))
    assert d["version"] == ver, f"{p.name}: version field mismatch"
    gen = d.get("generation")
    assert gen in gens, f"{p.name}: generation {gen!r} not declared in manifest"
    tpl = root / d["dockerfile"]
    assert tpl.is_file(), f"{p.name}: dockerfile {d['dockerfile']} missing"
    # 模板文件名必须对应代际，防止 g2 的定义指向 g1 的模板这类串台。
    name = tpl.name
    if gen == "g1":
        assert name in ("Dockerfile.5.4", "Dockerfile.g1"), f"{p.name}: {name} is not a G1 template"
    else:
        assert name == f"Dockerfile.{gen}", f"{p.name}: {name} != Dockerfile.{gen}"
    # G2/G3 用系统 OpenSSL：出现自建 toolchain 说明模板抄错了代。
    if gen in ("g2", "g3"):
        assert "openssl" not in d.get("toolchain", {}), f"{p.name}: {gen} must not vendor OpenSSL"
        assert not any("/opt/toolchain" in f for f in d["configure"]["flags"]), \
            f"{p.name}: {gen} flag points at the vendored toolchain"

# 每个版本在 toml 的 [artifact].targets 里声明自己要产出哪些平台，
# manifest.artifacts 必须与它完全一致（双向）。多一条就指到不存在的下载地址，
# 少一条就让已产出的平台无人知晓 —— 两种都会让 bin/install 说错话。
known = {"linux-x86_64", "linux-arm64", "darwin-x86_64", "darwin-arm64"}
by_ver = {v["version"]: v for v in m["versions"]}

# bin/install 的 UNAVAILABLE 声明了「该版本永远不会有」的平台（jessie 两代的
# linux-arm64，见其注释）。默认要求每个版本都覆盖两个 Linux 架构，被明确排除的
# 除外 —— 这样既不会漏掉真正该建的平台，也不用把例外表复制三份。
import re
mm = re.search(r'^UNAVAILABLE="([^"]*)"', (root / "bin" / "install").read_text(encoding="utf-8"), re.M)
excluded = {tuple(e.split(":", 1)) for e in (mm.group(1).split() if mm else [])}

for ver in scope:
    d = tomllib.load((root / "versions" / f"{ver}.toml").open("rb"))
    targets = set(d.get("artifact", {}).get("targets", []))
    assert targets, f"{ver}: [artifact].targets is missing"
    assert targets <= known, f"{ver}: unknown platform(s) {targets - known}"
    want = {"linux-x86_64", "linux-arm64"} - {p for (v, p) in excluded if v == ver}
    assert want <= targets, f"{ver}: must target {sorted(want)}"
    assert not ({p for (v, p) in excluded if v == ver} & targets), \
        f"{ver}: platform declared unavailable but still targeted"
    arts = by_ver[ver]["artifacts"]
    assert set(arts) == targets, f"{ver}: manifest artifacts {sorted(arts)} != toml targets {sorted(targets)}"
    for plat, a in arts.items():
        assert a["name"] == f"php-{ver}-{plat}.tar.gz", f"{ver}/{plat}: name {a['name']} != canonical"
print("ok")
PY
then
  pass "T3f/T3g/T3i matrix: 7 definitions, correct templates, no cross-generation drift"
else
  fail "T3f/T3g/T3i matrix: $(tail -2 "$tmp/matrix2.err")"
fi

# T3h: flag/version 匹配是行为测试，不是文本检查 —— 真的把 7 个版本各展开一遍。
if for v in 5.4.45 5.6.40 7.2.34 7.3.33 7.4.33 8.0.30 8.1.34; do
     python3 "$root/scripts/gen-build-inputs.py" "$v" >/dev/null || exit 1
   done 2>"$tmp/gen.err"; then
  pass "T3h build inputs expand for all 7 versions (no wrong-version configure flags)"
else
  fail "T3h build input expansion: $(tail -2 "$tmp/gen.err")"
fi

# T3j: planned 平台清单也必须是三处一致。少写一条，ARM/Mac 用户就会收到
# "unsupported" 而不是 "planned" —— 那是把"还没做"误报成"不做"。
gate_p="$(sed -n 's/^PLANNED="\(.*\)"$/\1/p' "$root/bin/install" | head -1)"
mplan="$(python3 -c 'import json,sys; print(" ".join(json.load(open(sys.argv[1],encoding="utf-8"))["platforms"]["planned"]))' "$root/manifest.json" 2>/dev/null || echo '__ERR__')"
if [ "$gate_p" = "$mplan" ]; then
  pass "T3j planned platforms match manifest ($gate_p)"
else
  fail "T3j planned drift: bin/install [$gate_p] != manifest [$mplan]"
fi

# T3k: SOURCES.json 必须是合并，不是重算。CI 每次只为一个版本拉源码，
# 若记账按目录重写，就会删掉其它版本的记录，「拉完 git diff 必须为空」这条
# 漂移门禁将永久失败，最终只剩被人关掉一个结局。
mkdir -p "$tmp/ledger"
printf '%s\n' '{"ghost-9.9.9.tar.gz": {"sha256": "'"$(printf '%064d' 1)"'"}}' > "$tmp/ledger/SOURCES.json"
: > "$tmp/ledger/real-1.0.tgz"
if python3 "$root/scripts/vendor-ledger.py" "$tmp/ledger" >/dev/null 2>&1 \
   && python3 - "$tmp/ledger/SOURCES.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "ghost-9.9.9.tar.gz" in d, "existing ledger entry was dropped"
assert "real-1.0.tgz" in d, "newly fetched file was not recorded"
print("ok")
PY
then
  pass "T3k vendor ledger merges (never drops entries for versions not fetched this run)"
else
  fail "T3k vendor ledger rewrote instead of merging"
fi

# T3l: 回填门禁必须按版本作用域。CI 与 l2 每次只为一个版本拉源码，门禁若扫描全部
# toml，只要还有一个版本没轮到冻结，单版本构建就会死在第一步 —— 2026-11-08 L2
# 实测正是如此：7.4.33 的源码已下载校验完，却被 5.6.40 的占位符堵住，编译一步没跑。
mkdir -p "$tmp/fill/versions" "$tmp/fill/vendor"
printf '%s\n' '{"php-a.tar.gz": {"sha256": "aaa111"}}' > "$tmp/fill/vendor/SOURCES.json"
printf 'version = "1.0.0"\nsha256 = "FILL:php-a.tar.gz"\n' > "$tmp/fill/versions/1.0.0.toml"
printf 'version = "2.0.0"\nsha256 = "FILL:php-b.tar.gz"\n' > "$tmp/fill/versions/2.0.0.toml"
if python3 "$root/scripts/fill-placeholders.py" "$tmp/fill" "$tmp/fill/vendor" --scope 1.0.0 \
        >"$tmp/fill/out" 2>"$tmp/fill/err" \
   && grep -q 'aaa111' "$tmp/fill/versions/1.0.0.toml" \
   && grep -q 'FILL:php-b.tar.gz' "$tmp/fill/versions/2.0.0.toml"; then
  pass "T3l fill gate is scope-aware (other versions' placeholders do not block this one)"
else
  fail "T3l scoped fill: $(tail -2 "$tmp/fill/err" 2>/dev/null)"
fi

# 反向：本轮版本自己的占位没解，必须硬失败；且报错里的文件名不能被正则吃掉尾引号
# （旧写法 `FILL:\S+` 报成 `FILL:php-b.tar.gz"`，看着像 toml 写坏了）。
if python3 "$root/scripts/fill-placeholders.py" "$tmp/fill" "$tmp/fill/vendor" --scope 2.0.0 \
        >/dev/null 2>"$tmp/fill/err2"; then
  fail "T3l2 in-scope unresolved placeholder must be a hard error"
elif grep -q 'FILL:php-b.tar.gz"' "$tmp/fill/err2"; then
  fail "T3l2 placeholder report swallowed the closing quote"
else
  pass "T3l2 in-scope placeholder fails loudly, filename reported without stray quote"
fi

# T3m: buildx 把 arm64 平台报成 `linux/arm64/v8`。按字面匹配 `linux/arm64` 会让
# pin-base / l2 把一个本来合格的 base 判成缺 arm64 —— 天天误报的警告最后只会被无视，
# 真正缺 arm64 时反而没人看。用真实 buildx 输出格式复现，验归一化与判定。
# 注入方式用导出的 bash 函数（同 tar 的处理）：MinGW 的临时目录是 C:/... 形式，
# 塞进 PATH 会被冒号截断。
docker() {
  case "$*" in
    *"buildx version"*) printf 'github.com/docker/buildx v0.0.0-stub\n'; return 0 ;;
    *imagetools*inspect*)
      cat <<'OUT'
Name:      debian:bullseye-slim
MediaType: application/vnd.docker.distribution.manifest.list.v2+json
Digest:    sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

Manifests:
  Platform:     linux/386
  Platform:     linux/amd64
  Platform:     linux/arm/v7
  Platform:     linux/arm64/v8
  Platform:     unknown/unknown
OUT
      return 0 ;;
  esac
  return 0
}
export -f docker
plats="$(bash "$root/scripts/image-platforms.sh" debian:bullseye-slim 2>/dev/null || true)"
if [ "$plats" = "linux/386 linux/amd64 linux/arm/v7 linux/arm64" ]; then
  pass "T3m arm64/v8 -> linux/arm64, attestation (unknown/unknown) dropped"
else
  fail "T3m platform normalization: got [$plats]"
fi

pinout="$(bash "$root/scripts/pin-base.sh" debian:bullseye-slim 2>&1 || true)"
if printf '%s\n' "$pinout" | grep -q 'amd64 + arm64 both present' \
   && ! printf '%s\n' "$pinout" | grep -q 'WARNING'; then
  pass "T3m pin-base sees arm64 in a real-format index (no false WARNING)"
else
  fail "T3m pin-base false positive: $(printf '%s\n' "$pinout" | tail -3)"
fi

if ! grep -q "awk '/Platform:/" "$root/scripts/l2.sh" "$root/scripts/pin-base.sh" 2>/dev/null; then
  pass "T3m platform detection has one implementation (scripts/image-platforms.sh)"
else
  fail "T3m platform detection duplicated in l2.sh / pin-base.sh"
fi
unset -f docker

# T3n: 定义里声明的 sha256 必须真的和下载到的字节比对过。只写不验的哈希不是冻结
# 输入，只是装饰 —— 上游换包、或有人手改定义，都会在构建中途变成看不懂的错误。
mkdir -p "$tmp/vh/versions" "$tmp/vh/vendor"
printf '%s\n' '[source]' 'url = "https://example.invalid/php-1.0.tar.gz"' \
  'path = "vendor/php-1.0.tar.gz"' 'sha256 = "aaaaaaaa"' > "$tmp/vh/versions/1.0.toml"
printf '%s\n' '{"php-1.0.tar.gz": {"sha256": "bbbbbbbb"}}' > "$tmp/vh/vendor/SOURCES.json"
if python3 "$root/scripts/verify-hashes.py" "$tmp/vh" "$tmp/vh/vendor" \
        >/dev/null 2>"$tmp/vh.err"; then
  fail "T3n declared/vendored hash mismatch must be refused"
elif grep -q 'aaaaaaaa' "$tmp/vh.err" && grep -q 'bbbbbbbb' "$tmp/vh.err"; then
  pass "T3n hash mismatch refused, both values reported"
else
  fail "T3n mismatch rejection message is unhelpful: $(tail -2 "$tmp/vh.err")"
fi

printf '%s\n' '{"php-1.0.tar.gz": {"sha256": "aaaaaaaa"}}' > "$tmp/vh/vendor/SOURCES.json"
printf '%s\n' '[source]' 'url = "https://example.invalid/php-2.0.tar.gz"' \
  'path = "vendor/php-2.0.tar.gz"' 'sha256 = "FILL:php-2.0.tar.gz"' > "$tmp/vh/versions/2.0.toml"
if python3 "$root/scripts/verify-hashes.py" "$tmp/vh" "$tmp/vh/vendor" >/dev/null 2>&1; then
  pass "T3n matching hash passes; unfrozen (FILL:) and not-yet-fetched inputs are skipped"
else
  fail "T3n verify-hashes rejected a valid tree"
fi

# T3o: configure 选项名必须对着该版本自己的 config.m4 校验，不能靠版本表记忆。
# 一棵假源码树就够复现两类真实事故：gd 在 7.4 从 --with-gd 改名成 --enable-gd
# （写旧名 → configure 只警告 → gd 整块静默缺席），以及漏写 --with-zlib
# （根本没有警告，编出来的 PHP 就是没有 gzencode）。
# tarball 必须落在 repo/vendor/ 下：那是 toml 里 [source].path 的相对根。
# 放错地方时 check-flags 会走 "skip: not vendored yet" 分支并 exit 0，
# 第一个断言就会假通过 —— 所以下面还要断言它真的读到了 flags。
mkdir -p "$tmp/t3o/repo/vendor" "$tmp/t3o/repo/versions"
python3 - "$tmp/t3o/repo" <<'PY'
import io, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
files = {
    "ext/gd/config.m4": "PHP_ARG_ENABLE([gd], [for GD support], "
                        "[AS_HELP_STRING([--enable-gd], [])], [no])\n",
    "ext/zlib/config0.m4": "PHP_ARG_WITH([zlib], [for ZLIB support], "
                           "[AS_HELP_STRING([--with-zlib[=DIR]], [])], [no])\n",
}
with tarfile.open(root / "vendor" / "php-9.9.9.tar.gz", "w:gz") as tf:
    for rel, body in files.items():
        data = body.encode()
        info = tarfile.TarInfo(f"php-9.9.9/{rel}")
        info.size = len(data)
        tf.addfile(info, io.BytesIO(data))
PY
mk_t3o() {  # $1 = flags 列表字面量
  printf '%s\n' 'version = "9.9.9"' '[source]' 'path = "vendor/php-9.9.9.tar.gz"' \
    '[configure]' "flags = [$1]" > "$tmp/t3o/repo/versions/9.9.9.toml"
}

mk_t3o '"--enable-gd", "--with-zlib"'
if python3 "$root/scripts/check-flags.py" "$tmp/t3o/repo" --versions 9.9.9 >"$tmp/t3o.ok" 2>&1 \
   && grep -q '9.9.9: 2 flags' "$tmp/t3o.ok"; then
  pass "T3o correct flags pass against the version's own config.m4"
else
  # 不加 grep 的话，"源码没 vendor → skip → exit 0" 会让这条断言假通过。
  fail "T3o check-flags rejected a valid definition: $(tail -2 "$tmp/t3o.ok")"
fi

mk_t3o '"--with-gd", "--with-zlib"'
if python3 "$root/scripts/check-flags.py" "$tmp/t3o/repo" --versions 9.9.9 >"$tmp/t3o.bad" 2>&1; then
  fail "T3o renamed option (--with-gd) must be rejected"
elif grep -q 'does not know --with-gd' "$tmp/t3o.bad" && grep -q 'did you mean: --enable-gd' "$tmp/t3o.bad"; then
  pass "T3o --with-gd rejected with the rename suggested"
else
  fail "T3o rejection message unhelpful: $(tail -2 "$tmp/t3o.bad")"
fi

mk_t3o '"--enable-gd"'
if python3 "$root/scripts/check-flags.py" "$tmp/t3o/repo" --versions 9.9.9 >"$tmp/t3o.miss" 2>&1; then
  fail "T3o omitted --with-zlib must be caught (silently absent extension)"
elif grep -q 'required extension not requested' "$tmp/t3o.miss" \
     && grep -q 'with-zlib' "$tmp/t3o.miss"; then
  pass "T3o omitted required extension reported by name"
else
  fail "T3o missing-extension message unhelpful: $(tail -2 "$tmp/t3o.miss")"
fi

# T3p: 「这个版本永远不会有」必须和「还没做」分开说。debian:jessie 的官方多架构
# 索引里没有 arm64（386/amd64/armv5/armv7），所以 5.4/5.6 的 linux-arm64 不会存在；
# 若只留在全局 PLANNED 里，ARM 用户会一直等一个永远不会出现的制品。
# 约束：UNAVAILABLE 的每条不得与该版本 targets 重叠，且必须覆盖 jessie 两代。
unavail="$(sed -n 's/^UNAVAILABLE="\(.*\)"$/\1/p' "$root/bin/install" | head -1)"
if python3 - "$root" "$unavail" <<'PY' 2>"$tmp/t3p.err"
import pathlib, sys, tomllib
root, raw = pathlib.Path(sys.argv[1]), sys.argv[2]
entries = raw.split()
assert entries, "UNAVAILABLE is empty"
for e in entries:
    ver, plat = e.split(":", 1)
    d = tomllib.loads((root / "versions" / f"{ver}.toml").read_text(encoding="utf-8"))
    targets = d.get("artifact", {}).get("targets", [])
    assert plat not in targets, f"{ver} calls {plat} unavailable but still lists it in targets"
assert {"5.4.45", "5.6.40"} <= {e.split(":")[0] for e in entries}, \
    "jessie-based versions must be listed in UNAVAILABLE"
print("ok")
PY
then
  pass "T3p unavailable platforms disjoint from targets and cover jessie ($unavail)"
else
  fail "T3p unavailable-platform contract: $(tail -2 "$tmp/t3p.err")"
fi

# T3q: 取包逻辑只能有一份实现。以前 g1/g2 各写一套 sources.list 加两档 fallback，
# bullseye 那次断连暴露了它们的共同缺陷：apt 一次失败就整层重来，8 分钟下完的
# 67.7 MB 全扔掉 —— 而 apt 本身支持续传，只是没人给它第二次机会。
# 现在四个 Dockerfile 一律 `sh /tmp/apt-install.sh <dist> <pkgs...>`，
# 重试 / 换源 / 续传都在脚本里，改一处四个模板同时受益。
if [ -f "$root/build/apt-install.sh" ] && sh -n "$root/build/apt-install.sh" 2>"$tmp/t3q.err"; then
  pass "T3q build/apt-install.sh exists and parses as POSIX sh"
else
  fail "T3q apt-install.sh: $(cat "$tmp/t3q.err" 2>/dev/null)"
fi

if grep -q '> /etc/apt/sources.list' "$root"/build/Dockerfile.g1 "$root"/build/Dockerfile.g2 \
     "$root"/build/Dockerfile.g3 "$root"/build/Dockerfile.5.4 2>/dev/null; then
  fail "T3q a Dockerfile writes sources.list itself again (two implementations of the same policy)"
else
  pass "T3q no Dockerfile writes /etc/apt/sources.list directly"
fi

used=0
for gen in g1 g2 g3 5.4; do
  grep -q 'sh /tmp/apt-install.sh' "$root/build/Dockerfile.$gen" && used=$((used + 1))
done
if [ "$used" -eq 4 ]; then
  pass "T3q all four Dockerfiles install build deps through apt-install.sh"
else
  fail "T3q only $used/4 Dockerfiles use apt-install.sh"
fi

missing=""
for want in 'Acquire::Retries' '--fix-missing' 'dpkg --configure -a' \
            'archive.debian.org' 'mirrors.aliyun.com' 'mirror.nju.edu.cn'; do
  grep -q -- "$want" "$root/build/apt-install.sh" || missing="$missing $want"
done
if [ -z "$missing" ]; then
  pass "T3q apt-install.sh keeps retry + resume + a three-mirror fallback chain"
else
  fail "T3q apt-install.sh missing:$missing"
fi

# T3r: build/Dockerfile.5.4 是 5.4.45 的专用轨道，configure flags 硬编码在文件里，
# 不读 build/.gen。也就是说改 versions/5.4.45.toml 不会影响它的产物 —— 2026-11-08
# 统一补基础扩展集时就漏了这一处，重编出来的 5.4.45 仍会静默缺 zlib/gzencode。
# 单向漂移门禁：toml 里声明的每个 flag，Dockerfile 里必须出现同名的那一个。
if python3 - "$root" <<'PY' 2>"$tmp/t3r.err"
import pathlib, sys, tomllib
root = pathlib.Path(sys.argv[1])
flags = tomllib.loads((root / "versions" / "5.4.45.toml").read_text(encoding="utf-8"))["configure"]["flags"]
dockerfile = (root / "build" / "Dockerfile.5.4").read_text(encoding="utf-8")
missing = [f for f in flags if f.split("=", 1)[0] not in dockerfile]
assert not missing, ("build/Dockerfile.5.4 hardcodes its flags and is out of sync with "
                     "versions/5.4.45.toml: " + ", ".join(missing))
print("ok")
PY
then
  pass "T3r Dockerfile.5.4 satisfies every flag declared in versions/5.4.45.toml"
else
  fail "T3r 5.4 flag drift: $(tail -2 "$tmp/t3r.err")"
fi

# T3s: 光看脚本里有没有 "--fix-missing" 这几个字不算验证。真正要证的是行为：
# 活源失败后会不会换源、换源后安装中途断连会不会续传、成不成之后会不会无谓地
# 继续砸后面的镜像。用假 apt-get 复现 2026-11-08 的那次事故（活源全灭，归档
# 源把 67.7 MB 下完卡在最后几个包，第二次调用 --fix-missing 才补齐）。
mkdir -p "$tmp/t3s/bin" "$tmp/t3s/etc/apt" "$tmp/t3s/lists" "$tmp/t3s/state"
cat > "$tmp/t3s/bin/apt-get" <<'SH'
#!/bin/sh
state="${APT_STATE:?}"
list="$(grep -m1 '^deb' "${APT_ETC:-/etc/apt}/sources.list" 2>/dev/null || true)"
printf 'apt-get %s | %s\n' "$*" "$list" >> "$state/calls"
case "$*" in
  update*)
    # 活源视作已被整体撤走：apt-get update 直接 100。
    case "$list" in *deb.debian.org*) exit 100 ;; esac
    exit 0
    ;;
  install*)
    # 归档源第一次安装断在最后几个包，第二次（带 --fix-missing）成功。
    case "$*" in *--fix-missing*) exit 0 ;; esac
    if [ -f "$state/failed_once" ]; then exit 0; fi
    : > "$state/failed_once"
    exit 100
    ;;
esac
exit 0
SH
cat > "$tmp/t3s/bin/dpkg" <<'SH'
#!/bin/sh
printf 'dpkg %s\n' "$*" >> "${APT_STATE:?}/calls"
exit 0
SH
chmod +x "$tmp/t3s/bin/apt-get" "$tmp/t3s/bin/dpkg"
# Git Bash 的 mktemp 返回 "C:\Users\...\Temp/tmp.XXXX"，直接把这种路径塞进 PATH
# 会被冒号切成两段（"C" 和 "\Users\..."），假 apt-get 根本不在搜索路径里。
# 用 cygpath -u 转成 /tmp/... 再加。这是本测试唯一需要转换的路径。
t3s_path="$tmp/t3s/bin"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) t3s_path="$(cygpath -u "$tmp/t3s/bin")" ;;
esac
run_apt_install() {  # $1 dist, $2 state dir, $3 log
  mkdir -p "$2"
  PATH="$t3s_path:$PATH" APT_STATE="$2" APT_ETC="$tmp/t3s/etc/apt" \
    APT_LISTS="$tmp/t3s/lists" \
    sh "$root/build/apt-install.sh" "$1" build-essential libzip-dev >"$3" 2>&1
}

# 分支一：还在维护的 suite（bookworm）先试活源；活源挂掉后应当落到国内归档镜像，
# 中途断连要用 --fix-missing 续传，成功之后不许再白跑后面的镜像。
if run_apt_install bookworm "$tmp/t3s/a" "$tmp/t3s/a.out"; then
  calls="$tmp/t3s/a/calls"
  first="$(grep -m1 '^apt-get' "$calls" | sed 's/.*| //')"
  last="$(grep '^apt-get.*install' "$calls" | tail -1 | sed 's/.*| //')"
  if grep -q -- '--fix-missing' "$calls" \
     && grep -q 'dpkg --configure -a' "$calls" \
     && printf '%s' "$first" | grep -q 'deb.debian.org' \
     && printf '%s' "$last" | grep -q 'mirrors.aliyun.com' \
     && ! grep -q 'nju\|archive\.debian\.org' "$calls"; then
    pass "T3s live suite: live fails -> domestic archive succeeds, resume via --fix-missing, stops there"
  else
    fail "T3s live-suite chain: first=[$first] last=[$last] calls=$(wc -l < "$calls")"
  fi
else
  fail "T3s apt-install.sh exited non-zero on a recoverable network failure: $(tail -3 "$tmp/t3s/a.out")"
fi

# 分支二：EOL 的 suite（bullseye）必须**一次都不碰** deb.debian.org。它的
# security 索引仍在发布，但索引点名的文件已从 pool 清走：update 成功、install
# 404，白下 70 MB 才失败。这条断言守的就是「别再把活源排在 EOL suite 前面」。
if run_apt_install bullseye "$tmp/t3s/b" "$tmp/t3s/b.out"; then
  calls="$tmp/t3s/b/calls"
  first="$(grep -m1 '^apt-get' "$calls" | sed 's/.*| //')"
  if ! grep -q 'deb.debian.org' "$calls" \
     && printf '%s' "$first" | grep -q 'mirrors.aliyun.com'; then
    pass "T3s EOL suite: deb.debian.org never contacted, starts at the archive mirror"
  else
    fail "T3s EOL suite still probes the live mirror: first=[$first]"
  fi
else
  fail "T3s EOL-suite install failed: $(tail -3 "$tmp/t3s/b.out")"
fi

# T3t: Dockerfile 不许 COPY 仓库里不存在（或已被 .gitignore 掉）的文件。
# g1 与 5.4 曾 COPY keys/jessie.gpg，而 keys/ 在 .gitignore 里：新克隆没有这个
# 文件，docker build 停在 COPY 行，报的错与真正的失败原因（缺密钥）毫无关系。
# vendor/ 与 build/.gen/ 是构建期产物，由 l2.sh 第 1、2 步准备，这里跳过。
bad=""
for f in "$root"/build/Dockerfile.*; do
  while read -r src; do
    case "$src" in
      vendor/*|build/.gen/*) continue ;;
    esac
    if [ ! -e "$root/$src" ]; then
      bad="$bad $src(missing)"
    elif git -C "$root" rev-parse --git-dir >/dev/null 2>&1 \
         && git -C "$root" check-ignore -q "$src"; then
      bad="$bad $src(ignored)"
    fi
  done < <(awk '$1=="COPY"{for(i=2;i<=NF;i++) if($i !~ /^--/){print $i; break}}' "$f")
done
if [ -z "$bad" ]; then
  pass "T3t every COPY source exists and is tracked (fresh clone can build)"
else
  fail "T3t Dockerfile copies untracked/missing paths:$bad"
fi

# 分支三：APT_MIRROR_MAIN 插队。这是网络不通时唯一能走的路（代理 / 内网镜像），
# 而它走的是跟候选链不同的分支 —— 曾经 TRUST_ORDER 只在主链里赋值，override 分支
# 一进来就在 set -u 下退出，等于把逃生口焊死了。这条断言守的就是它必须能跑。
mkdir -p "$tmp/t3s/c"
if PATH="$t3s_path:$PATH" APT_STATE="$tmp/t3s/c" APT_ETC="$tmp/t3s/etc/apt" \
     APT_LISTS="$tmp/t3s/lists" \
     APT_MIRROR_MAIN="http://override.example/debian" \
     APT_MIRROR_SEC="http://override.example/debian-security" \
     sh "$root/build/apt-install.sh" bookworm build-essential \
     >"$tmp/t3s/c.out" 2>&1; then
  calls="$tmp/t3s/c/calls"
  if grep -q 'override\.example' "$calls" \
     && printf '%s' "$(grep '^apt-get.*install' "$calls" | tail -1)" | grep -q 'override\.example' \
     && ! grep -q 'aliyun\|nju\|archive\.debian\.org' "$calls"; then
    pass "T3s APT_MIRROR_MAIN override is used first and short-circuits the chain"
  else
    fail "T3s override ignored: $(head -3 "$calls")"
  fi
else
  fail "T3s override path crashed: $(tail -3 "$tmp/t3s/c.out")"
fi

# T3u: gd 的 freetype 支持不能用运气换。PHP 7.2/7.3 的 ext/gd 只认
# --with-freetype-dir，其 config.m4 用 AC_PATH_PROG 找 freetype-config，找不到就
# AC_MSG_ERROR 中止 configure；而 bullseye 的 libfreetype6-dev 已经不装这个脚本
# （freetype 2.10 起上游转交 pkg-config）。2026-11-08 的 7.2.34 L2 就死在
# `#10 12.20 configure: error: freetype-config not found.`。
# 三条断言各自守一个断点：①shim 是合法 POSIX sh；②g2 真的把它装进镜像；
# ③smoke 有函数级门禁 —— 少了第三条，shim 哪天失效也没人知道，只会得到一份
# 「图像函数都在、唯独画不上字」的静默降级制品。
if [ -f "$root/build/freetype-config-shim.sh" ] \
   && sh -n "$root/build/freetype-config-shim.sh" 2>"$tmp/t3u.err"; then
  pass "T3u build/freetype-config-shim.sh exists and parses as POSIX sh"
else
  fail "T3u freetype-config shim: $(cat "$tmp/t3u.err" 2>/dev/null)"
fi

if grep -q 'build/freetype-config-shim.sh /tmp/freetype-config' "$root/build/Dockerfile.g2" \
   && grep -q 'install -m 0755 /tmp/freetype-config /usr/local/bin/freetype-config' \
        "$root/build/Dockerfile.g2"; then
  pass "T3u Dockerfile.g2 installs the freetype-config shim when the distro dropped it"
else
  fail "T3u Dockerfile.g2 no longer installs the freetype-config shim (7.2/7.3 configure will fail)"
fi

if grep -q 'imagettftext' "$root/scripts/smoke-artifact.sh" \
   && grep -q 'with-freetype' "$root/scripts/smoke-artifact.sh"; then
  pass "T3u smoke gates gd freetype with imagettftext for versions that declare it"
else
  fail "T3u smoke lost the gd-freetype gate — a silent freetype regression would ship"
fi

# 行为断言：只看脚本里有没有 "--cflags" 这几个字不算验证。用假 pkg-config 复现
# bullseye 的输出，确认 shim 真的把参数翻译成 freetype2.pc 的值 —— 如果它把参数
# 原样透传，PHP 拿到的 FREETYPE_CFLAGS 就是一句 "unsupported option"，链接时才发现。
mkdir -p "$tmp/t3u/bin"
cat > "$tmp/t3u/bin/pkg-config" <<'SH'
#!/bin/sh
case "$*" in
  "--cflags freetype2")            echo "-I/usr/include/freetype2" ;;
  "--libs freetype2")              echo "-lfreetype" ;;
  "--modversion freetype2")        echo "2.10.4" ;;
  "--variable=prefix freetype2")   echo "/usr" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$tmp/t3u/bin/pkg-config"
t3u_path="$tmp/t3u/bin"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) t3u_path="$(cygpath -u "$tmp/t3u/bin")" ;;
esac
t3u_cflags="$(PATH="$t3u_path:$PATH" sh "$root/build/freetype-config-shim.sh" --cflags 2>&1 || true)"
t3u_libs="$(PATH="$t3u_path:$PATH" sh "$root/build/freetype-config-shim.sh" --libs 2>&1 || true)"
if [ "$t3u_cflags" = "-I/usr/include/freetype2" ] && [ "$t3u_libs" = "-lfreetype" ]; then
  pass "T3u freetype-config shim translates --cflags/--libs into freetype2.pc values"
else
  fail "T3u shim passthrough broken: cflags=[$t3u_cflags] libs=[$t3u_libs]"
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
  # ASDF_PHP_DIST_DIR points at an empty dir so a real ~/.asdf-php-dist on the
  # developer's machine cannot shadow the fake release server.
  run_install() { # <relative install path under $tmp>
    ( cd "$tmp" &&
      PATH="$fakebin:$PATH" \
      ASDF_INSTALL_VERSION="$ver" \
      ASDF_INSTALL_PATH="$1" \
      ASDF_PHP_DIST_DIR="$tmp/no-local-dist" \
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
  elif grep -q 'nothing to install for darwin-arm64' "$tmp/plat.out" \
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

  # T8c: 已规划但还没制品的平台要给不同的说法。「还没做」被误报成「不做」，
  # 是开源项目最常见的信任损耗之一，所以这条单独守。
  if ( cd "$tmp" && PATH="$fbd:$PATH" \
        ASDF_INSTALL_VERSION="$ver" ASDF_INSTALL_PATH="i_plan" \
        ASDF_PHP_RELEASE_BASE="http://127.0.0.1:$port" \
          bash "$root/bin/install" ) >"$tmp/plan.out" 2>&1; then
    fail "T8c darwin-arm64 should have been refused but the install succeeded"
  elif grep -q 'planned but not published yet' "$tmp/plan.out"; then
    pass "T8c planned platform -> says 'planned', not 'unsupported'"
  else
    fail "T8c missing planned hint: $(tail -2 "$tmp/plan.out")"
  fi

  # T8d: Rosetta 回退。把 darwin-x86_64 伪装成已发布，arm64 机器应走回退分支；
  # 本机不是 macOS，没有 /usr/bin/arch，所以必须停在「请安装 Rosetta」而不是
  # 直接去下 x86_64 制品。正向回退路径只能在 macOS runner 上验（见 CI）。
  if ( cd "$tmp" && PATH="$fbd:$PATH" \
        ASDF_PHP_SUPPORTED="darwin-x86_64" ASDF_PHP_PLANNED="" \
        ASDF_INSTALL_VERSION="$ver" ASDF_INSTALL_PATH="i_rosetta" \
        ASDF_PHP_RELEASE_BASE="http://127.0.0.1:$port" \
          bash "$root/bin/install" ) >"$tmp/rosetta.out" 2>&1; then
    fail "T8d Rosetta fallback must not silently install x86_64 without Rosetta"
  elif grep -qi 'rosetta' "$tmp/rosetta.out"; then
    pass "T8d darwin-arm64 -> x86_64 fallback, asks for Rosetta when missing"
  else
    fail "T8d wrong Rosetta path: $(tail -2 "$tmp/rosetta.out")"
  fi

  # T9: 本地构建优先。这是「一个制品都不发布」时的实际工作方式 —— l2.sh 把
  # tar.gz + sidecar 归档到 ~/.asdf-php-dist，install 先看那里。所以即使 Release
  # 完全不可达，只要本机编过，就装得上。没有这条，「不发布」等于「不能用」。
  local_dist="$tmp/local-dist"
  mkdir -p "$local_dist"
  make_artifact "$local_dist/$name" 1
  sha256_of "$local_dist/$name" > "$local_dist/$name.sha256"
  if ( cd "$tmp" && PATH="$fakebin:$PATH" \
        ASDF_INSTALL_VERSION="$ver" ASDF_INSTALL_PATH="i_local" \
        ASDF_PHP_DIST_DIR="$local_dist" \
        ASDF_PHP_RELEASE_BASE="http://127.0.0.1:1/unreachable" \
          bash "$root/bin/install" ) >"$tmp/local.out" 2>&1 \
     && [ -x "$tmp/i_local/bin/php" ] \
     && grep -q 'using the locally built' "$tmp/local.out"; then
    pass "T9 local build dir wins over an unreachable release (zero published artifacts)"
  else
    fail "T9 local build path: $(tail -3 "$tmp/local.out")"
  fi

  # T9b: 本地制品坏掉必须拒，并且指出是本地副本的问题 —— 否则用户会以为
  # 是上游发布坏了，跑去查网络和代理。
  printf '%064d\n' 0 > "$local_dist/$name.sha256"
  if ( cd "$tmp" && PATH="$fakebin:$PATH" \
        ASDF_INSTALL_VERSION="$ver" ASDF_INSTALL_PATH="i_local_bad" \
        ASDF_PHP_DIST_DIR="$local_dist" \
        ASDF_PHP_RELEASE_BASE="http://127.0.0.1:1/unreachable" \
          bash "$root/bin/install" ) >"$tmp/localbad.out" 2>&1; then
    fail "T9b a corrupt local artifact should have been refused"
  elif grep -q 'sha256 mismatch' "$tmp/localbad.out" \
       && grep -q 'rebuild with' "$tmp/localbad.out"; then
    pass "T9b corrupt local artifact -> mismatch + tells you to rebuild locally"
  else
    fail "T9b wrong rejection: $(tail -2 "$tmp/localbad.out")"
  fi
fi

# T8e: 「这个版本永远不会有」和「还没做」必须说成两句话。jessie 没有 arm64 索引，
# 5.4/5.6 的 linux-arm64 不会存在；若它落进 planned，ARM 用户会一直等一个永远不来
# 的制品，而正确答案是「换 7.2+」。
mkdir -p "$tmp/fakebin-arm"
cat > "$tmp/fakebin-arm/uname" <<'FAKE_ARM'
#!/bin/sh
case "${1:-}" in
  -m) echo aarch64 ;;
  *)  echo Linux ;;
esac
FAKE_ARM
chmod +x "$tmp/fakebin-arm/uname"
if ( cd "$tmp" && PATH="$tmp/fakebin-arm:$PATH" \
      ASDF_INSTALL_VERSION="5.4.45" ASDF_INSTALL_PATH="i_arm54" \
      bash "$root/bin/install" ) >"$tmp/arm54.out" 2>&1; then
  fail "T8e 5.4.45 on linux-arm64 should have been refused"
elif grep -q 'will not be built for linux-arm64' "$tmp/arm54.out" \
     && ! grep -q 'planned but not published' "$tmp/arm54.out"; then
  pass "T8e jessie generation: arm64 refused as 'will not be built', not 'planned'"
else
  fail "T8e wrong message for 5.4.45 on arm64: $(tail -2 "$tmp/arm54.out")"
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
