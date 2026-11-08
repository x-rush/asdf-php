# build-inputs

Archived copies of the pinned build inputs for asdf-php. **Not needed to use the plugin.**

`asdf plugin add` clones the `v2` branch, so anything committed there is downloaded by
every user at install time. The frozen source tarballs are build-side material only —
users install a prebuilt tarball and never compile anything. Keeping 25 MB of sources on
the plugin branch made every install heavier for no benefit, so they live here instead.

## What is here

| File | Purpose |
|---|---|
| `vendor/php-5.4.45.tar.gz` | PHP source for the 5.4.45 artifact |
| `vendor/openssl-1.0.2u.tar.gz` | OpenSSL pinned for PHP 5.x |
| `vendor/bison-2.7.tar.gz` | PHP 5.x needs bison 2.x; current distros ship 3.x |
| `vendor/redis-2.2.8.tgz` | redis extension, last release supporting PHP 5.4 |
| `vendor/swoole-1.10.5.tgz` | swoole 1.x last release |
| `vendor/SOURCES.json` | URLs + SHA256 for every input (also kept on `v2`) |
| `keys/jessie.gpg` | Debian archive signing key, dearmored |
| `keys/jessie-key.asc` | Same key, armored original |

## When you need this

Only when rebuilding an artifact. Normal builds do not require it: `scripts/vendor.sh`
re-fetches every input from upstream and verifies it against `vendor/SOURCES.json`, which
is why that one file stays on `v2`.

This branch exists for the case where an upstream tarball disappears — Debian archive
shrinks, old github tags move, a PECL release is pulled. Then restore from here:

```bash
git clone --branch build-inputs https://github.com/x-rush/asdf-php.git bi
cp -r bi/vendor bi/keys <your-plugin-checkout>/
```

Verify before building; do not trust a copy that was not checked:

```bash
cd <your-plugin-checkout> && bash scripts/vendor.sh   # re-verifies every sha256
```

## Integrity

SHA256 for each input is recorded in `vendor/SOURCES.json` on the `v2` branch, which is the
contract. A file here that does not match it is worthless — `vendor.sh` will say so.

These are upstream sources, redistributed unmodified under their own licenses
(PHP License 3.01, OpenSSL, GPLv3 for bison, Apache-2.0 for swoole). See `NOTICE` on `v2`.
