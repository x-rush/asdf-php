#!/usr/bin/env python3
"""Verify that every configure flag in a version definition is actually
recognised by THAT version's PHP source tree.

Why this exists
---------------
PHP's configure silently tolerates unknown options: `--with-gd` on PHP 8.0 and
`--with-zlib` being omitted altogether both produce a build that compiles fine,
installs fine and then lacks the extension at runtime. The only symptom is a
missing function, discovered much later by whoever calls it. Autoconf prints one
"unrecognized option" line in a thousand-line log and carries on.

Guessing option names from a version table is how those bugs happen: gd is
--with-gd up to 7.3, --enable-gd from 7.4; zip is --enable-zip up to 7.3,
--with-zip from 7.4; the --with-*-dir flags vanished in 7.4. So this script does
not carry a table of names at all -- it reads the option names out of the frozen
sources' own config.m4 files, which are the definition of what configure accepts.

Usage
-----
    scripts/check-flags.py <repo-root> [--versions 7.4.33,8.1.34]

Exit code 1 when a version declares a flag its own source tree does not know.
Versions whose tarball is not vendored yet are skipped with a note, because
`--versions` builds are supposed to work one version at a time.
"""

from __future__ import annotations

import pathlib
import re
import sys
import tarfile
import tomllib

# PHP_ARG_ENABLE / PHP_ARG_WITH are called either as PHP_ARG_ENABLE([name], ...)
# (modern, bracketed) or PHP_ARG_ENABLE(name, ...) (5.x, bare). Autoconf's
# m4_esyscmd/m4_normalize variants also appear, hence the permissive character
# class: some names are written as [gd], others as gd, others as [[gd]].
ARG_RE = re.compile(
    r"PHP_ARG_(ENABLE|WITH|REPLACE)\s*\(\s*\[{0,2}([A-Za-z0-9_\-]+)",
    re.MULTILINE,
)

# Every --flag we may care about lives in one of these. The root configure.ac
# holds the core (php-*) options; ext/*/config*.m4 the extension ones.
MEMBER_RE = re.compile(r"^php-[^/]+/(configure\.ac|configure\.in)$|^php-[^/]+/ext/[^/]+/config[0-9]*\.m4$")


def known_options(src: pathlib.Path) -> set[str]:
    """Option names this PHP version accepts, from its own m4 sources."""
    names: set[str] = set()
    with tarfile.open(src, "r:gz") as tf:
        for m in tf.getmembers():
            if not m.isfile() or not MEMBER_RE.match(m.name):
                continue
            fh = tf.extractfile(m)
            if fh is None:
                continue
            text = fh.read().decode("utf-8", "replace")
            for kind, name in ARG_RE.findall(text):
                if kind == "REPLACE":
                    continue
                # PHP_ARG_ENABLE([gd]) defines --enable-gd, PHP_ARG_WITH([gd])
                # defines --with-gd. The prefix is the whole point: gd moved
                # from one to the other in 7.4 and that rename is exactly what
                # this check is meant to catch.
                names.add(f"{kind.lower()}-{name.lower()}")
    return names


# Extensions that are off by default in every supported version and whose
# absence breaks ordinary projects rather than exotic ones. Omitting one is
# undetectable at build time -- configure has no idea you wanted zlib -- so the
# requirement has to be written down and enforced here.
REQUIRED: dict[str, str] = {
    "zlib": "gzencode / gzopen",
    "iconv": "iconv (uses glibc, no extra lib)",
    "phar": "Phar class — composer.phar cannot run without it",
    "bcmath": "bcadd",
    "sockets": "socket_create",
    "exif": "exif_read_data",
    "pcntl": "pcntl_fork",
    "opcache": "opcache (5.5+; compiled but not enabled by default)",
}


def ext_flags(flags: list[str]) -> list[str]:
    out = []
    for f in flags:
        if not f.startswith("--"):
            continue
        out.append(f.split("=", 1)[0][2:].lower())
    return out


def missing_required(flags: list[str], accepted: set[str]) -> list[str]:
    """Required extensions this version could build but the definition skips."""
    missing = []
    have = set(ext_flags(flags))
    for stem, why in REQUIRED.items():
        # The prefix follows the version: gd is --with-gd up to 7.3 and
        # --enable-gd after. Accept whichever form this source tree declares,
        # and stay silent when the extension simply does not exist in it
        # (opcache before 5.5).
        forms = [f"{k}-{stem}" for k in ("enable", "with") if f"{k}-{stem}" in accepted]
        if not forms:
            continue
        if not have.intersection(forms):
            missing.append(f"--{forms[0]} ({why})")
    return missing


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: check-flags.py <repo-root> [--versions a,b]", file=sys.stderr)
        return 2
    root = pathlib.Path(argv[1])
    only: set[str] = set()
    for i, a in enumerate(argv[1:], 1):
        if a == "--versions" and i < len(argv) - 1:
            only = {v.strip() for v in argv[i + 1].split(",") if v.strip()}

    failures = 0
    checked = 0
    for toml_path in sorted((root / "versions").glob("*.toml")):
        ver = toml_path.stem
        if only and ver not in only:
            continue
        data = tomllib.loads(toml_path.read_text(encoding="utf-8"))
        src = root / data["source"]["path"]
        flags = data.get("configure", {}).get("flags", [])
        if not src.is_file():
            print(f"skip {ver}: {data['source']['path']} not vendored yet")
            continue

        accepted = known_options(src)
        unknown = [name for name in ext_flags(flags) if name not in accepted]
        absent = missing_required(flags, accepted)
        checked += 1
        if not absent and not unknown:
            print(f"ok   {ver}: {len(flags)} flags, all recognised by php-{ver}")
            continue
        failures += 1
        if absent:
            print(f"FAIL {ver}: required extension not requested — {', '.join(absent)}")
        if unknown:
            print(f"FAIL {ver}: source tree does not know {', '.join('--' + u for u in unknown)}")
            # A near miss is nearly always a rename that happened in this very
            # version (gd: with->enable). Printing the candidates turns a
            # mystery into a one-line fix.
            for u in unknown:
                stem = u.replace("with-", "").replace("enable-", "").replace("-dir", "")
                near = sorted(n for n in accepted if stem and stem in n and n != u)
                if near:
                    print(f"       did you mean: {', '.join('--' + n for n in near)}")
    if not checked:
        print("nothing checked — no vendored sources for the requested versions")
        return 0
    print(f"\n{checked - failures}/{checked} version definitions pass")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
