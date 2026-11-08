# asdf-php

Self-contained PHP builds for [asdf](https://asdf-vm.com), covering seven versions from 5.4.45 to 8.1.34. Each one is compiled once in a pinned container against frozen inputs, and the result bundles every non-glibc shared library it needs — so the PHP you get runs on a machine that has none of its build dependencies.

Two ways to get one, same result:

```bash
bash scripts/l2.sh 7.4.33 --install   # build it here, install straight into asdf
asdf install php 7.4.33               # install a prebuilt artifact, if one is published
```

`bin/install` checks `~/.asdf-php-dist` first, so a build you did yourself is all it needs. Publishing is optional; it only saves the next person from building the same thing.

## Who this is for

This is a narrow tool. Saying so up front saves everyone a wasted install.

| If you are… | Verdict |
|---|---|
| Keeping a legacy PHP 5.x/7.x project buildable on Linux x86_64, after a distro upgrade broke the source build | this is exactly what it is for |
| Needing a checksum-verified PHP in CI without a compiler on the runner | yes — build once, then install from `~/.asdf-php-dist` |
| Looking for PHP 8.2+ or a current stable release | no — the matrix is frozen at the last EOL releases, 5.4.45 through 8.1.34 |
| On macOS or arm64 Linux | no — no artifact has been built for either; those recipes are unverified |
| Planning to put an EOL PHP behind a public endpoint | no — see [Security](#security) |

## Why this exists

Compiling PHP 5.x or 7.x on a current distro fails for reasons that have nothing to do with PHP:

- **Bison 3 vs Bison 2** — PHP 5.x needs bison 2.x; every current distro ships bison 3.
- **OpenSSL ABI** — PHP 5.x predates OpenSSL 1.1; PHP 8.0 cannot use OpenSSL 3. Neither links against a distro build of the wrong generation.
- **Missing headers** — `libcurl4-gnutls-dev`, `libxml2-dev`, `re2c` appear and disappear across releases.
- **Silent feature loss** — the worst one. A configure flag the distro no longer supports does not fail; it disappears. You get a build that runs, and find out months later that `gzencode` does not exist.

In-place building plugins handle this with per-distro detection, and when a probe fails they drop the feature and carry on. This repository moves the compile into a container with frozen inputs, declares each version's flags in one file, and checks them against that version's own `ext/*/config.m4` — so a flag that would be ignored fails the build instead of the user.

## Status

Every version below has been compiled and smoke-tested on **linux-x86_64**. "compiles" means that version's own `configure` accepted every declared flag and `make` produced a working CLI — not that an artifact was published.

| PHP | Gen | Base | Notes |
|---|---|---|---|
| 5.4.45 | g1 | debian:jessie | bison 2.7 + vendored OpenSSL 1.0.2u; redis 2.2.8, swoole 1.10.5 |
| 5.6.40 | g1 | debian:jessie | same toolchain as 5.4 |
| 7.2.34 | g2 | debian:bullseye | `-fcommon` (GCC 10) + freetype-config shim; redis 5.3.7, swoole 4.8.13 |
| 7.3.33 | g2 | debian:bullseye | same as 7.2 |
| 7.4.33 | g2 | debian:bullseye | `--enable-gd`, `--with-zip`; redis 5.3.7, swoole 4.8.13 |
| 8.0.30 | g2 | debian:bullseye | system OpenSSL 1.1.1 |
| 8.1.34 | g3 | debian:bookworm | system OpenSSL 3.0 |

The 5.x artifacts were additionally unpacked on bullseye (glibc 2.31) and verified there — old PHP running on a newer libc is the entire point of bundling.

`linux-arm64` and macOS are not built: this project has no arm64 or macOS build host. See [Platform support](#platform-support).

## Requirements

- Linux `x86_64`
- Docker, for building — the compile happens in a container so that 5.4 and 5.6 can see the toolchain they were written for
- `curl`, `tar`, and `sha256sum` **or** `shasum` (macOS has no `sha256sum`; the plugin picks whichever exists)
- asdf 0.16 or newer

Installing a published artifact needs none of the build machinery — only `curl`, `tar` and a checksum tool.

## Install

### From a build you make here

```bash
git clone https://github.com/x-rush/asdf-php.git
cd asdf-php

bash scripts/l2.sh 7.4.33 --install
```

That compiles the version, runs the smoke test against a fresh unpack path, archives the tarball to `~/.asdf-php-dist`, and extracts it into `~/.asdf/installs/php/7.4.33`. Nothing else is downloaded afterwards.

Then select it:

```bash
asdf global php 7.4.33     # or: asdf local php 7.4.33
php -v
php -m | grep -E 'redis|swoole'
```

### From a published artifact

```bash
asdf plugin add php https://github.com/x-rush/asdf-php.git
asdf install php 7.4.33
```

If nothing is published for your platform, the installer says so and points at `scripts/l2.sh <version> --install` rather than failing with a 404.

Either way the checksum is verified before anything is unpacked, and a mismatch aborts with nothing written to the install path.

## Supported versions

`asdf list-all php` reads `versions.txt`. It lists what can be installed — from a published artifact or from a local build.

| PHP | Status |
|---|---|
| 5.4.45 | compiles; artifact published |
| 5.6.40 | compiles |
| 7.2.34 | compiles |
| 7.3.33 | compiles |
| 7.4.33 | compiles; artifact published |
| 8.0.30 | compiles |
| 8.1.34 | compiles |
| 8.2+ | not started |

EOL versions are pinned to their final upstream release and never rebuilt. A "current" channel for 8.2+ would follow upstream releases; it does not exist yet.

Three build generations cover all seven versions, split on the OpenSSL ABI rather than on the version number:

| Gen | PHP | OpenSSL | Base |
|---|---|---|---|
| g1 | 5.4, 5.6 | 1.0.2u vendored (5.x cannot link 1.1+) | debian:jessie |
| g2 | 7.2, 7.3, 7.4, 8.0 | system 1.1.1 (3.0 is unsupported before 8.1) | debian:bullseye |
| g3 | 8.1+ | system 3.0 | debian:bookworm |

## Security

**EOL PHP has no upstream security fixes. This is an offline tool, not a web server runtime.**

PHP 5.4 reached end of life in September 2015 and will not receive security patches from anyone. Treat a 5.4 install as a legacy migration aid: run it locally, or in an isolated container, to keep an old project buildable. Do not expose it to the internet, and do not put credentials or user data behind it.

Every build uses the exact inputs recorded in `versions/<version>.toml` and `vendor/SOURCES.json`. An artifact is verified by SHA256 before it is unpacked; a local build is verified the same way as a downloaded one.

## How it works

```
bash scripts/l2.sh 7.4.33 --install
  ├─ vendor sources       fetch + hash-verify into vendor/
  ├─ expand definition    versions/7.4.33.toml -> build/.gen/7.4.33.{flags,env,ext}
  ├─ docker build         pinned base, configured from .gen, make, extensions
  ├─ extract artifact     tarball + .sha256 sidecar
  ├─ archive              copy to ~/.asdf-php-dist (out/ is wiped per run)
  ├─ smoke                relocate, conf.d scanning, redis/swoole, function probe
  └─ install              unpack into ~/.asdf/installs/php/7.4.33
```

`bin/install` is about 90 lines of shell. It does not compile, does not read build sources, and does not probe your system for headers: it takes a tarball from `~/.asdf-php-dist` or from Releases, verifies it, and unpacks it.

A failure at smoke is a hard stop. A WARN-free build is not enough — the artifact has to prove it relocates, loads its extensions from a stranger path, and exposes the functions it claims.

## Relocatable layout

The artifact works from any directory. Nothing is hardcoded to the build prefix:

- `bin/php` is a wrapper that points `PHPRC`, `PHP_INI_SCAN_DIR` and `extension_dir` at the unpack location before exec'ing `libexec/php.bin`.
- `lib/` holds every non-glibc shared library the binary needs. glibc itself is deliberately not bundled — shipping an old libc against a newer kernel is how you get mystery crashes. This makes the artifact portable across distros, not across decades of glibc.
- `bin/phpize`, `bin/php-config`, `bin/pear` and `bin/phar` are rewritten to follow the same prefix, so building a PECL extension against the installed PHP works.

## Extensions

Every version is built with the same baseline: `zlib`, `iconv`, `phar`, `bcmath`, `sockets`, `exif`, `pcntl`, plus `opcache` on 5.5 and newer. These are all off by default in PHP itself, and a build that omits one does not fail — it silently lacks the functions later, which is almost impossible to diagnose from a configure log. Flags are checked against that version's own `config.m4` (`scripts/check-flags.py`) and the smoke test probes the functions in the finished artifact, so an omission fails the build instead of the user.

`opcache` is compiled in but not enabled: `zend_extension=opcache` in an ini file turns it on, which matters for php-fpm and not for CLI.

`redis` and `swoole` are compiled in and enabled through `etc/conf.d/`. Both are loaded and asserted by the smoke test. Versions are pinned per generation — `redis 2.2.8` / `swoole 1.10.5` for 5.x, `redis 5.3.7` / `swoole 4.8.13` from 7.2 up.

Build your own extension against the installed copy:

```bash
pecl install xdebug-2.2.7
```

`php-config` and `phpize` resolve relative to wherever you installed the PHP, so this works without setting anything by hand.

## Verifying a build

`scripts/test.sh` checks the static contracts — definitions, configure flags, the platform gate. `verify/e2e.sh` checks the other half: it calls `bin/install` with exactly the environment asdf passes, installs each tarball from `~/.asdf-php-dist` into a temporary prefix, and inspects the result. No network, no Release, no asdf binary required.

```bash
bash verify/e2e.sh                        # every artifact in ~/.asdf-php-dist
bash verify/e2e.sh 7.4.33 8.1.34          # just these versions
ASDF_PHP_DIST_DIR=/media/backup bash verify/e2e.sh
```

Per version it asserts: `php` / `phpize` / `php-config` are executable, redis and swoole load, `extension_dir` and `include_path` follow the unpack prefix, the feature probes (`gzencode`, `iconv`, `bcadd`, `socket_create`, `exif_read_data`, `pcntl_fork`, `Phar`, `imagettftext`) all answer, the first `pear` run consumes the relocation marker, and no `/opt/php/` build prefix survives in `bin/`, `etc/` or `lib/php/`. Exit code is 0 only if every requested version passed.

The artifacts are Linux ELF binaries, so on macOS or Windows run it in a Linux container:

```bash
docker run --rm -v "$PWD:/repo" -v "$HOME/.asdf-php-dist:/dist:ro" debian:bookworm-slim \
  bash -c 'cd /repo && ASDF_PHP_DIST_DIR=/dist bash verify/e2e.sh'
```

## Platform support

`bin/install` checks the platform before downloading and fails with a clear message rather than a 404:

| Platform | Status |
|---|---|
| linux-x86_64 | supported |
| linux-arm64 | not built — no arm64 build host has ever run this |
| darwin-x86_64 | not built — `build/macos.sh` exists and has never been executed on a Mac |
| darwin-arm64 | not built |
| anything else | rejected with an explicit message |

`bin/install` still separates *planned* from *unsupported*, so an ARM user gets the reason and the local-build command instead of a dead end. But nothing on this list is scheduled: what exists is what has been compiled and verified on linux-x86_64, and the other three rows would need hardware this project does not have.

The one place where a platform will genuinely never appear is `linux-arm64` for 5.4 and 5.6. Both build on `debian:jessie`, whose official multi-arch index carries only `386 / amd64 / armv5 / armv7` — no arm64 at all. Reaching arm64 would mean a newer base, which raises glibc from 2.19 to 2.24 or later, and running against 2.19-era systems is the entire reason those two versions are here. So for those versions the installer says *will not be built*, names the reason, and points you at 7.2+ instead of leaving you to wait for a milestone that is not coming.

`manifest.json` → `platforms` is the source of truth for this table, and the test suite fails if the table, the manifest and the platform gate in `bin/install` ever disagree.

### macOS: what is actually different

**This section describes the design of `build/macos.sh`, not a path that works today.** No Mac has ever run it end-to-end, and neither has `--platform linux-arm64` been run on an arm64 host. Treat both as recipes awaiting their first real build, not as verified support.

macOS does not let you bundle its system libraries. libSystem and libc++ come from the OS, so a macOS artifact is tied to its `MACOSX_DEPLOYMENT_TARGET` (11.0) and cannot be as portable as the Linux builds — those bundle everything except glibc.

What the macOS build does instead:

- bundles every non-system dependency and rewrites the load commands to `@loader_path` with `install_name_tool`, so the prefix stays movable;
- re-signs each rewritten Mach-O ad-hoc (`codesign --force --sign -`), because arm64 refuses to run a binary with an invalid signature;
- sizes for the smallest sensible matrix: **one `darwin-x86_64` artifact covers Intel Macs natively and Apple Silicon through Rosetta 2**. Native `darwin-arm64` is added only for 8.0/8.1, where the audience is mostly Apple Silicon. PHP 5.x on arm64 macOS is deliberately not attempted: it needs patches for 2014-era C code that modern Clang rejects, and Rosetta already covers those users.

If your Mac is arm64 and only an x86_64 artifact exists, the plugin tells you to run `softwareupdate --install-rosetta --agree-to-license` instead of quietly downloading something that will not execute.

## Building

Build inputs are kept out of the install path — the plugin branch stays small on purpose, because `asdf plugin add` clones it. The pinned sources live on the `build-inputs` branch and are re-fetched (and hash-verified) by `scripts/vendor.sh`.

```bash
# one-time per version: fetch frozen sources, verify, fill versions/<ver>.toml
bash scripts/vendor.sh --versions 7.4.33

# resolve the base image index digest (must contain linux/amd64 AND linux/arm64)
bash scripts/pin-base.sh debian:bullseye-slim --write

# build + smoke, Linux, native arch
bash scripts/l2.sh 7.4.33
bash scripts/l2.sh 7.4.33 --platform linux-arm64   # needs a native arm64 host

# build on macOS (no Docker there)
bash build/macos.sh 8.1.34 --arch arm64
```

Artifacts land in `out/` and in `~/.asdf-php-dist`. `out/` is wiped at the start of every run, which is why the archive step exists: build five versions in a row and you still have all five.

Adding a version means adding `versions/<ver>.toml` — not editing a Dockerfile or a script. `build/Dockerfile.g1|g2|g3` read every flag, CFLAGS override and extension list from that file through `scripts/gen-build-inputs.py`, so there is exactly one place per version where build inputs are declared. The 5.4 track is the single exception: `build/Dockerfile.5.4` predates the generator and hardcodes its flag list, so `T3r` cross-checks it against `versions/5.4.45.toml` — otherwise a definition edit would silently leave the 5.4.45 artifact behind.

One part of the build cannot be pinned by this repository: build dependencies come from a Debian mirror. Debian moves an EOL suite to `archive.debian.org`, whose Fastly front end is unreliable from some networks — a 67 MB download that dies on the last three packages used to abort the whole layer and start again from zero. `build/apt-install.sh` walks a source chain (live mirror → Chinese archive mirrors → `archive.debian.org`), keeps apt's partial download cache across attempts, and resumes with `--fix-missing` instead of refetching. The domestic mirrors come before the canonical archive because `archive.debian.org` is served through Fastly and measured 139 kB/s from mainland China — 8 minutes for a 67 MB layer — while those mirrors carry byte-identical packages at MB/s; `archive.debian.org` stays last so no region loses a source. Behind a proxy or an internal mirror, skip the chain entirely:

```bash
ASDF_PHP_APT_MIRROR_MAIN=http://mirror.example/debian-archive/debian \
ASDF_PHP_APT_MIRROR_SEC=http://mirror.example/debian-archive/debian-security \
bash scripts/l2.sh 7.4.33
```

(`HTTP_PROXY`/`HTTPS_PROXY` from your environment are forwarded to `docker build` automatically; nothing to do there.)

The build is pinned to a dated base image digest. It produces the tarball, runs the smoke test against a fresh unpack path, and refuses to hand it over on a warning. `scripts/pack-artifact.sh` holds the packaging logic shared by all three templates and the macOS path: bundle runtime libs, relocate, move the prefix to a stranger path and verify extensions still load, then tar + sha256.

`scripts/test.sh` runs the static contract suite: definition/schema consistency, per-version configure-flag validity, no source-compilation regressions, support-matrix drift, platform-gate drift, the local-build install path, and the offline fallback path.

A note on why configure flags are gated twice: a wrong flag does not fail the build, it produces an artifact that runs but silently lacks features (`--with-mysql` vanished in PHP 7.0, gd's `--with-gd` became `--enable-gd` and zip's `--enable-zip` became `--with-zip`, both in 7.4, gd's `--with-jpeg-dir` became `--with-jpeg` in 7.4). `gen-build-inputs.py` rejects them up front, `check-flags.py` verifies them against each version's own `ext/*/config.m4`, and the smoke test additionally calls `imagecreatefromjpeg`, `mb_strlen`, `curl_init`, `mysqli_connect`, `gzencode`, `iconv`, `bcadd`, `socket_create` and friends on the finished artifact.

## Publishing (optional)

Nothing here requires a release. If you do want to share a build, tag it `php-<version>`, attach the tarball and its `.sha256` sidecar, and put the checksum in `manifest.json` so `bin/install` can verify what it downloads. `versions.txt` is what `asdf list-all` shows.

## Uninstall

```bash
asdf uninstall php 5.4.45
asdf plugin remove php
```

## License

Apache License 2.0 — see [LICENSE](LICENSE). Derived from the asdf PHP plugin lineage; see `NOTICE` for attribution if you redistribute.
