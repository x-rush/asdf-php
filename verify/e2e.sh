#!/usr/bin/env bash
# End-to-end check of bin/install against real artifacts, no network involved.
#
# smoke-artifact.sh answers "is this tarball well-formed"; this answers the next
# question: "does the plugin's own installer turn it into a working PHP in an
# asdf-shaped layout". It calls bin/install exactly the way asdf does
# (ASDF_INSTALL_VERSION + ASDF_INSTALL_PATH) with ASDF_PHP_DIST_DIR pointed at a
# local directory, so it never touches GitHub Releases.
#
#   bash verify/e2e.sh                       # every artifact present in the dist dir
#   bash verify/e2e.sh 7.4.33 8.1.34         # just these
#   ASDF_PHP_DIST_DIR=/media/backup bash verify/e2e.sh
#
# Exit code is 0 only if every requested version passed.
set -u
set -o pipefail

here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
dist=${ASDF_PHP_DIST_DIR:-$HOME/.asdf-php-dist}
work=${ASDF_PHP_E2E_ROOT:-$(mktemp -d "${TMPDIR:-/tmp}/asdf-php-e2e.XXXXXX")}

fail=0
bad() { echo "  FAIL $*"; fail=1; }
ok()  { echo "  ok   $*"; }

# Versions are not built at the same moment, so a single run over everything can
# mix an old artifact's results into a new build's. Naming them is allowed for
# exactly that reason.
if [ "$#" -gt 0 ]; then
  versions="$*"
else
  versions=$(ls "$dist"/php-*-linux-x86_64.tar.gz 2>/dev/null |
             sed 's#.*/php-##; s#-linux-x86_64.tar.gz$##' | sort -V)
fi

if [ -z "$versions" ]; then
  echo "no artifacts in $dist" >&2
  echo "build one first: bash scripts/l2.sh 7.4.33 --install" >&2
  exit 1
fi

echo "dist: $dist"
echo "prefix root: $work"
echo

for v in $versions; do
  tarball="$dist/php-$v-linux-x86_64.tar.gz"
  echo "########## $v ##########"
  if [ ! -f "$tarball" ]; then
    echo "  SKIP no artifact at $tarball"
    continue
  fi

  p="$work/$v"
  if ! ASDF_INSTALL_VERSION="$v" ASDF_INSTALL_PATH="$p" ASDF_PHP_DIST_DIR="$dist" \
       bash "$root/bin/install"; then
    bad "bin/install exited non-zero"
    continue
  fi

  [ -x "$p/bin/php" ]        && ok "bin/php executable"        || bad "no bin/php"
  [ -x "$p/bin/phpize" ]     && ok "bin/phpize executable"     || bad "no bin/phpize"
  [ -x "$p/bin/php-config" ] && ok "bin/php-config executable" || bad "no bin/php-config"
  [ -d "$p/lib/php/extensions" ] && ok "extension_dir present" || bad "no lib/php/extensions"

  [ -x "$p/bin/php" ] || continue

  echo "  $( "$p/bin/php" -v | head -1 )"

  # Extensions are the reason this plugin exists; a PHP that starts but has lost
  # redis or swoole is a broken install, not a smaller one.
  "$p/bin/php" -m | grep -qiE '^redis$'  && ok "redis loaded"  || bad "redis not loaded"
  "$p/bin/php" -m | grep -qiE '^swoole$' && ok "swoole loaded" || bad "swoole not loaded"

  # The prefix moved from the build path to $p; both ini values have to follow it
  # or extensions resolve against a directory that no longer exists.
  ext_dir=$("$p/bin/php" -r 'echo ini_get("extension_dir");')
  inc_path=$("$p/bin/php" -r 'echo get_include_path();')
  case "$ext_dir" in
    "$p"/*) ok "extension_dir follows prefix ($ext_dir)" ;;
    *)      bad "extension_dir does not follow prefix: $ext_dir" ;;
  esac
  case "$inc_path" in
    *"$p"*) ok "include_path follows prefix" ;;
    *)      bad "include_path does not follow prefix: $inc_path" ;;
  esac

  # Feature probes: the silent-loss cases this repo exists to prevent.
  "$p/bin/php" -r '
    $c = ["gzencode", "iconv", "bcadd", "socket_create", "exif_read_data", "pcntl_fork"];
    $bad = 0;
    foreach ($c as $f) { if (!function_exists($f)) { echo "missing $f\n"; $bad = 1; } }
    if (!class_exists("Phar")) { echo "missing Phar\n"; $bad = 1; }
    if (!function_exists("imagettftext")) { echo "missing imagettftext\n"; $bad = 1; }
    exit($bad);
  ' && ok "feature probes" || bad "feature probes"

  # pear/pecl carry the old prefix inside serialized pear.conf, which cannot be
  # rewritten with sed: the length prefixes would be wrong. The wrapper relocates
  # on first run, so running it here is the test, not a warm-up.
  if [ -x "$p/bin/pear" ]; then
    if out=$("$p/bin/pear" version 2>&1); then
      ok "pear runs on first use ($(echo "$out" | head -1))"
    else
      bad "pear failed: $(echo "$out" | head -3 | tr '\n' ' ')"
    fi
  else
    echo "  --   no pear in this version"
  fi

  # Nothing may still point at the build prefix. grep -I skips binaries so the
  # php executable itself does not produce a false positive.
  leftover=$(cd "$p" && grep -rIl '/opt/php/' bin etc lib/php 2>/dev/null)
  if [ -n "$leftover" ]; then
    bad "build prefix left in: $(echo "$leftover" | tr '\n' ' ')"
  else
    ok "no build prefix in bin/ etc/ lib/php"
  fi

  # The marker is written at pack time and consumed by the first pear run above.
  # Versions that ship no pear never trigger it, so the check only applies where
  # there was something to trigger.
  if [ -x "$p/bin/pear" ]; then
    if [ -e "$p/etc/.pear-relocate" ]; then
      bad "relocation marker still present after pear ran"
    else
      ok "relocation marker consumed"
    fi
  fi
  echo
done

if [ "$fail" -eq 0 ]; then
  echo "RESULT: all checks passed"
else
  echo "RESULT: failures above"
fi
exit "$fail"
