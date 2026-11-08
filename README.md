# asdf-php

Prebuilt, self-contained PHP builds for [asdf](https://asdf-vm.com) — install PHP in seconds, without a compiler, without touching your system libraries.

```
asdf plugin add php https://github.com/x-rush/asdf-php.git
asdf install php 5.4.45
```

## Why this exists

The existing asdf PHP plugins compile PHP from source on your machine. That works for recent versions on a recent distro, and falls apart everywhere else:

- **Bison 3 vs Bison 2** — PHP 5.x needs bison 2.x; every current distro ships bison 3.
- **OpenSSL ABI** — PHP 5.x predates OpenSSL 1.1; a distro OpenSSL 3 build cannot link against it.
- **Missing headers** — `libcurl4-gnutls-dev`, `libxml2-dev`, `re2c` appear and disappear across releases.
- **Build time** — 20 to 40 minutes when it works, and a configure failure when it does not.

This plugin removes the compiler from the user's machine entirely. Builds happen once, in a pinned container, against frozen inputs. What you download is a tarball with every non-glibc shared library bundled inside.

## Status

**Early.** Only `5.4.45` on `linux-x86_64` is published today. The rest of the support matrix below is planned, not available — `asdf list-all php` shows exactly what exists.

The point of this plugin is the versions a source build cannot reach. For PHP 7.x and 8.x, a source-building plugin still works on most machines, just slowly.

**If you need PHP 7.x or 8.x today, use the v1 plugin.** It is still on the `master` branch and compiles from source:

```bash
asdf plugin add php https://github.com/x-rush/asdf-php.git master
```

Come back here for PHP 5.x, or when 7.x/8.x artifacts land. The two branches coexist; neither overwrites the other.

## Requirements

- Linux `x86_64` (the only platform with published artifacts today)
- `curl`, `tar`, and `sha256sum` **or** `shasum` (macOS has no `sha256sum`; the plugin picks whichever exists)
- asdf 0.16 or newer

`linux-arm64`, `darwin-x86_64` and `darwin-arm64` are built but not published yet. Other platforms fail with an explicit message rather than a broken install — see [Platform support](#platform-support).

## Install

```bash
asdf plugin add php https://github.com/x-rush/asdf-php.git
asdf install php 5.4.45
```

Pin it for a project:

```bash
asdf local php 5.4.45          # writes .tool-versions
```

Or globally:

```bash
asdf global php 5.4.45
```

Verify:

```bash
php -v
php -m | grep -E 'redis|swoole'
```

## Supported versions

`status` is honest: a version is either **published** (downloadable now) or **scaffolded** (definition, template and CI matrix exist, artifact not built yet).

| PHP | Status | linux-x86_64 | linux-arm64 | darwin-x86_64 | darwin-arm64 |
|---|---|---|---|---|---|
| 5.4.45 | **published** | yes | scaffolded | scaffolded | via Rosetta |
| 5.6.40 | scaffolded | — | scaffolded | scaffolded | via Rosetta |
| 7.2.34 | scaffolded | — | scaffolded | scaffolded | via Rosetta |
| 7.3.33 | scaffolded | — | scaffolded | scaffolded | via Rosetta |
| 7.4.33 | scaffolded | — | scaffolded | scaffolded | via Rosetta |
| 8.0.30 | scaffolded | — | scaffolded | scaffolded | scaffolded |
| 8.1.34 | scaffolded | — | scaffolded | scaffolded | scaffolded |
| 8.2+ | current channel, not implemented | — | — | — | — |

EOL versions are pinned to their final upstream release and rebuilt never. Current versions (8.2 and newer) will follow upstream releases through a separate channel, once that channel exists.

Three build generations cover all seven versions, split on the OpenSSL ABI rather than on the version number:

| Gen | PHP | OpenSSL | Base |
|---|---|---|---|
| g1 | 5.4, 5.6 | 1.0.2u vendored (5.x cannot link 1.1+) | debian:jessie |
| g2 | 7.2, 7.3, 7.4, 8.0 | system 1.1.1 (3.0 is unsupported before 8.1) | debian:bullseye |
| g3 | 8.1+ | system 3.0 | debian:bookworm |

`manifest.json` is the machine-readable version of this table, including artifact SHA256 sums.

## Security

**EOL PHP has no upstream security fixes. This is an offline tool, not a web server runtime.**

PHP 5.4 reached end of life in September 2015 and will not receive security patches from anyone. Treat a 5.4 install as a legacy migration aid: run it locally, or in an isolated container, to keep an old project buildable. Do not expose it to the internet, and do not put credentials or user data behind it.

Every artifact is built with the exact inputs recorded in `versions/<version>.toml` and `vendor/SOURCES.json`, and verified by SHA256 on download. Nothing is fetched at runtime beyond the release asset itself.

## How it works

```
asdf install php 5.4.45
  └─ bin/install
       ├─ download php-5.4.45-linux-x86_64.tar.gz from GitHub Releases
       ├─ verify SHA256 against the .sha256 sidecar
       ├─ unpack into ~/.asdf/installs/php/5.4.45
       └─ run bin/php -v to confirm the result
```

`bin/install` is ~45 lines of shell. It does not compile, does not read the build sources, and does not probe your system for headers.

## Relocatable layout

The artifact works from any directory. Nothing is hardcoded to the build prefix:

- `bin/php` is a wrapper that points `PHPRC`, `PHP_INI_SCAN_DIR` and `extension_dir` at the unpack location before exec'ing `libexec/php.bin`.
- `lib/` holds every non-glibc shared library the binary needs. glibc itself is deliberately not bundled — shipping an old libc against a newer kernel is how you get mystery crashes. This makes the artifact portable across distros, not across decades of glibc.
- `bin/phpize`, `bin/php-config`, `bin/pear` and `bin/phar` are rewritten to follow the same prefix, so building a PECL extension against the installed PHP works.

## Extensions

Every version is built with the same baseline: `zlib`, `iconv`, `phar`, `bcmath`, `sockets`, `exif`, `pcntl`, plus `opcache` on 5.5 and newer. These are all off by default in PHP itself, and a build that omits one does not fail — it just silently lacks the functions later, which is almost impossible to diagnose from a configure log. The build now verifies each flag against that version's own `config.m4` (`scripts/check-flags.py`) and the smoke test probes the functions in the finished artifact, so an omission fails the build instead of the user.

`opcache` is compiled in but not enabled: `zend_extension=opcache` in an ini file turns it on, which matters for php-fpm and not for CLI.

`redis` and `swoole` are compiled in and enabled through `etc/conf.d/`. Both are loaded and asserted by the release smoke test. Versions are pinned per PHP generation — `redis 2.2.8` / `swoole 1.10.5` for 5.x, `redis 5.3.7` / `swoole 4.8.13` from 7.2 up.

Build your own extension against the installed copy:

```bash
pecl install xdebug-2.2.7
```

`php-config` and `phpize` resolve relative to wherever you installed the PHP, so this works without setting anything by hand.

## Platform support

`bin/install` checks the platform before downloading and fails with a clear message rather than a 404:

| Platform | Status |
|---|---|
| linux-x86_64 | supported |
| linux-arm64 | planned for 7.2+ / **never for 5.4 and 5.6** — see below |
| darwin-x86_64 | planned |
| darwin-arm64 | planned |
| anything else | rejected with an explicit message |

"planned" and "not happening" are different messages on purpose. If you land here on an ARM box before the artifact exists, you get *planned but not published yet*, not *unsupported*.

The one place where a platform will genuinely never appear is `linux-arm64` for 5.4 and 5.6. Both build on `debian:jessie`, whose official multi-arch index carries only `386 / amd64 / armv5 / armv7` — no arm64 at all. Reaching arm64 would mean a newer base, which raises glibc from 2.19 to 2.24 or later, and running against 2.19-era systems is the entire reason those two versions are here. So for those versions the installer says *will not be built*, names the reason, and points you at 7.2+ instead of leaving you to wait for a milestone that is not coming.

`manifest.json` → `platforms` is the source of truth for this table, and the test suite fails if the table, the manifest and the platform gate in `bin/install` ever disagree.

### macOS: what is actually different

macOS does not let you bundle its system libraries. libSystem and libc++ come from the OS, so a macOS artifact is tied to its `MACOSX_DEPLOYMENT_TARGET` (11.0) and cannot be as portable as the Linux builds — those bundle everything except glibc.

What the macOS build does instead:

- bundles every non-system dependency and rewrites the load commands to `@loader_path` with `install_name_tool`, so the prefix stays movable;
- re-signs each rewritten Mach-O ad-hoc (`codesign --force --sign -`), because arm64 refuses to run a binary with an invalid signature;
- sizes for the smallest sensible matrix: **one `darwin-x86_64` artifact covers Intel Macs natively and Apple Silicon through Rosetta 2**. Native `darwin-arm64` is added only for 8.0/8.1, where the audience is mostly Apple Silicon. PHP 5.x on arm64 macOS is deliberately not attempted: it needs patches for 2014-era C code that modern Clang rejects, and Rosetta already covers those users.

If your Mac is arm64 and only an x86_64 artifact exists, the plugin tells you to run `softwareupdate --install-rosetta --agree-to-license` instead of quietly downloading something that will not execute.

## Building from source

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

Adding a version means adding `versions/<ver>.toml` — not editing a Dockerfile or a script. `build/Dockerfile.g1|g2|g3` read every flag, CFLAGS override and extension list from that file through `scripts/gen-build-inputs.py`, so there is exactly one place per version where build inputs are declared.

The build is pinned to a dated base image digest. It produces the tarball, runs the smoke test against a fresh unpack path, and refuses to publish on a warning. `scripts/pack-artifact.sh` holds the packaging logic shared by all three templates and the macOS path: bundle runtime libs, relocate, move the prefix to a stranger path and verify extensions still load, then tar + sha256.

`scripts/test.sh` runs the static contract suite: definition/schema consistency, per-version configure-flag validity, no source-compilation regressions, support-matrix drift, platform-gate drift, and the offline fallback path.

A note on why configure flags are gated twice: a wrong flag does not fail the build, it produces an artifact that runs but silently lacks features (`--with-mysql` vanished in PHP 7.0, `--with-gd` became `--enable-gd` in 8.1, gd's `--with-jpeg-dir` became `--with-jpeg` in 7.4). `gen-build-inputs.py` rejects them up front, and the smoke test additionally calls `imagecreatefromjpeg`, `mb_strlen`, `curl_init`, `mysqli_connect` and friends on the finished artifact.

## Uninstall

```bash
asdf uninstall php 5.4.45
asdf plugin remove php
```

## License

Apache License 2.0 — see [LICENSE](LICENSE). Derived from the asdf PHP plugin lineage; see `NOTICE` for attribution if you redistribute.
