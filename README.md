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

- Linux `x86_64`
- `curl`, `sha256sum`, `tar` (present on any normal distro)
- asdf 0.16 or newer

`linux-arm64` and macOS builds are in progress. Other platforms fail with an explicit message rather than a broken install — see [Platform support](#platform-support).

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

| PHP | Status | linux-x86_64 | linux-arm64 | macOS |
|---|---|---|---|---|
| 5.4.45 | **published** | yes | planned | planned |
| 5.6.40 | planned | — | — | — |
| 7.2.34 | planned | — | — | — |
| 7.3.33 | planned | — | — | — |
| 7.4.33 | planned | — | — | — |
| 8.0.30 | planned | — | — | — |
| 8.1.34 | planned | — | — | — |
| 8.2+ | current channel, not implemented | — | — | — |

EOL versions are pinned to their final upstream release and rebuilt never. Current versions (8.2 and newer) will follow upstream releases through a separate channel, once that channel exists.

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

`5.4.45` ships with `redis 2.2.8` and `swoole 1.10.5` compiled in, enabled through `etc/conf.d/`. Both are loaded and asserted by the release smoke test.

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
| linux-arm64 | in progress |
| darwin-x86_64 | in progress |
| darwin-arm64 | in progress |
| anything else | rejected with an explicit message |

`manifest.json` → `platforms` is the source of truth for this table, and the test suite fails if the table, the manifest and the platform gate in `bin/install` ever disagree.

A macOS caveat worth stating up front: macOS does not let you bundle its system libraries. libSystem and libc++ come from the OS, so a macOS artifact is tied to the macOS versions it can run on and cannot be as portable as the Linux builds. Linux artifacts bundle everything except glibc; macOS will be scoped to the runner images it is built on.

## Building from source

Build inputs are kept out of the install path — the plugin branch stays small on purpose, because `asdf plugin add` clones it. The pinned sources live on the `build-inputs` branch.

```bash
# one-time: fetch frozen sources and verify against SOURCES.json
bash scripts/vendor.sh

# build locally in Docker (Linux x86_64)
bash scripts/l2.sh
```

The build is a multi-stage Dockerfile pinned to a dated base image digest. It produces the tarball, runs the smoke test against a fresh unpack path, and refuses to publish on a warning.

`scripts/test.sh` runs the static contract suite: definition/schema consistency, no source-compilation regressions, support-matrix drift, and off-line fallbacks.

## Uninstall

```bash
asdf uninstall php 5.4.45
asdf plugin remove php
```

## License

Apache License 2.0 — see [LICENSE](LICENSE). Derived from the asdf PHP plugin lineage; see `NOTICE` for attribution if you redistribute.
