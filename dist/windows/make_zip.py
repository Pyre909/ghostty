"""
Builds Ghostty's portable Windows zips.

    python3 dist/windows/make_zip.py --arch x86_64 --version 1.4.1

writes, in zig-out/dist (or --out):

    ghostty-1.4.1-windows-x86_64.zip      the app: bin, share, LICENSE.txt
                                          and THIRD-PARTY-NOTICES.txt, in a
                                          ghostty-1.4.1-windows-x86_64 folder
    ghostty-1.4.1-windows-x86_64-pdb.zip  the program databases, in the same
                                          folder, so that unzipping both in
                                          one place puts each .pdb beside its
                                          program, where debuggers look

and prints their SHA-256 sums the way sha256sum does. It builds with the
zig on PATH (or --zig), ReleaseFast with the debug information kept for the
.pdb files, from a checkout whose tracked files have no uncommitted changes
(unless --allow-dirty).

The zips are reproducible: their entries are sorted, they hold no directory
entries and no owners, and every entry has one time, SOURCE_DATE_EPOCH or
else the time of the HEAD commit. Two runs on the same build with the same
Python (its zlib compresses) give the same bytes.

THIRD-PARTY-NOTICES.txt follows what the build links, not a list kept by
hand. `zig build windows-packages` (src/build/WindowsPackages.zig) reports
every package with the paths the app links from it, and
dist/windows/third-party.json adds what the report cannot know:

    vendored    code copied into this repository, by path, with its
                license texts;
    embedded    files in this repository that the app embeds whole (with
                @embedFile), which the report cannot see, with their
                license texts; a font's copyright notice is read from the
                font itself;
    packages    the texts, by package name, for a fetched package that has
                no license file at its root;
    installed   files the build installs rather than links (the ConPTY
                host, the themes, bash-preexec), by installed path, each
                naming the package or vendored entry it comes from. Each
                path must be in the app.

A fetched package's license texts are the files at its root named LICENSE,
LICENCE, COPYING, NOTICE, UNLICENSE or OFL, optionally with a -SUFFIX and a
.txt, .md or .rst extension. A path in this repository is Ghostty's own
unless it is vendored, and a path with a "vendor" component must be
vendored, so that new vendored code cannot slip in unnoticed.

Two parts of the toolchain are always linked: Zig's standard library and
compiler_rt (Zig's LICENSE) and mingw-w64's C runtime (its COPYING),
including its printf and number conversion, whose gdtoa files carry their
own notices, read from Zig's copy of them. The LLVM runtime libraries Zig
compiles in (libc++, libc++abi, libunwind) need no notice: the LLVM
exception to their Apache-2.0 license waives its notice conditions for
portions embedded in a compiled program.
https://llvm.org/LICENSE.txt
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import json
import os
import posixpath
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zipfile
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
OVERRIDES = REPO / "dist" / "windows" / "third-party.json"

# The PE machine type of each architecture's programs.
ARCHES = {"x86_64": 0x8664, "aarch64": 0xAA64}

# Everything the build installs in bin. The .pdb files go to the -pdb zip.
BIN = frozenset(
    {
        "ghostty.exe",
        "ghostty.pdb",
        "ghostty.com",
        "ghostty-launcher.pdb",
        "conpty.dll",
        "OpenConsole.exe",
        "conpty-LICENSE.txt",
    }
)

# Files and non-empty directories in share that Ghostty needs at run time.
SHARE_FILES = ("share/terminfo/ghostty.terminfo",)
SHARE_DIRS = ("share/ghostty/shell-integration", "share/ghostty/themes")

# https://semver.org's regular expression. The version also names the
# zips, and this admits no path separators.
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$",
    re.ASCII,
)

LICENSE_FILE = re.compile(
    r"^(licen[cs]e|copying|notice|unlicense|ofl)(-[a-z0-9]+)?(\.(txt|md|rst))?$",
    re.ASCII | re.IGNORECASE,
)

FONTS = (".ttf", ".otf")

# Zip times start in 1980.
ZIP_EPOCH = 315532800

# A zip entry's time: year, month, day, hour, minute, second.
DateTime = tuple[int, int, int, int, int, int]


class Error(Exception):
    pass


@dataclass
class Component:
    """One part of the app in THIRD-PARTY-NOTICES.txt."""

    name: str
    license: str | None = None
    versions: list[str] = field(default_factory=list)
    url: str | None = None
    note: str | None = None
    # (label, text) pairs.
    texts: list[tuple[str, str]] = field(default_factory=list)


def read_text(path: Path) -> str:
    """A license text, with LF line ends, without trailing spaces or blank
    lines at either end. Texts that are not UTF-8 are read as Latin-1."""
    data = path.read_bytes()
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        text = data.decode("latin-1")
    lines = [
        line.rstrip()
        for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    ]
    while lines and not lines[-1]:
        lines.pop()
    while lines and not lines[0]:
        lines.pop(0)
    return "\n".join(lines)


def excerpt(text: str, start: str, end: str, where: str) -> str:
    """The lines from the first that contains `start` to the first from there
    on that contains `end`, both included."""
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if start in line:
            break
    else:
        raise Error(f"{where}: no line contains {start!r}")
    for j in range(i, len(lines)):
        if end in lines[j]:
            return "\n".join(lines[i : j + 1])
    raise Error(f"{where}: no line from {start!r} on contains {end!r}")


def check_keys(entry: dict[str, Any], allowed: set[str], what: str) -> None:
    """Fails on a key third-party.json does not use, such as a misspelt
    one, which would otherwise leave a text out without a word."""
    unknown = sorted(set(entry) - allowed)
    if unknown:
        raise Error(f"{OVERRIDES.name}: {what} has unknown keys {unknown}")


def text_of(
    repo: Path, spec: dict[str, Any], package: Path | None = None
) -> tuple[str, str]:
    """A text that third-party.json names: a file in this repository
    ("file") or in the package ("package_file"), whole or the lines from
    one marker to another ("from" and "to"). It is labelled by its name in
    the package, or by its base name for a file in this repository, whose
    path means nothing to someone reading the notices."""
    check_keys(spec, {"file", "package_file", "from", "to"}, f"the text {spec}")
    if ("file" in spec) == ("package_file" in spec):
        raise Error(
            f"{OVERRIDES.name}: {spec} names neither or both of file and package_file"
        )
    if "file" in spec:
        name = spec["file"]
        path, label = repo / name, posixpath.basename(name)
    elif package is None:
        raise Error(f"{OVERRIDES.name}: {spec} is not in a package")
    else:
        name = spec["package_file"]
        path, label = package / name, name
    if not path.is_file():
        raise Error(f"{path} is missing")
    text = read_text(path)
    if "from" in spec or "to" in spec:
        if "from" not in spec or "to" not in spec:
            raise Error(f"{name}: an excerpt needs both 'from' and 'to'")
        return f"{label} (excerpt)", excerpt(text, spec["from"], spec["to"], name)
    return label, text


def license_files(directory: Path) -> list[tuple[str, str]]:
    """The license texts of a package: its license files at the root, and
    every file in a LICENSES folder there, where a package that follows
    REUSE (https://reuse.software) keeps one file per license."""
    if not directory.is_dir():
        raise Error(f"{directory}: the package's directory is missing")
    found = []
    for p in directory.iterdir():
        if p.is_file() and LICENSE_FILE.match(p.name):
            found.append(p)
        elif p.is_dir() and p.name.lower() == "licenses":
            found += [f for f in p.iterdir() if f.is_file()]
    names = [(p.relative_to(directory).as_posix(), p) for p in found]
    names.sort(key=lambda n: (n[0].casefold(), n[0]))
    return [(name, read_text(p)) for name, p in names]


def font_copyright(path: Path) -> str:
    """A font's copyright notice: name ID 0 in its name table, from the
    record for Windows in US English. The OFL asks that every copy of a
    font carry it. https://learn.microsoft.com/typography/opentype/spec/name"""
    data = path.read_bytes()
    if data[:4] not in (b"\0\1\0\0", b"OTTO", b"true"):
        raise Error(f"{path} is not a TrueType or OpenType font")
    try:
        (tables,) = struct.unpack_from(">H", data, 4)
        for i in range(tables):
            tag, _, offset, _ = struct.unpack_from(">4sIII", data, 12 + 16 * i)
            if tag != b"name":
                continue
            _, records, strings = struct.unpack_from(">HHH", data, offset)
            for j in range(records):
                key = struct.unpack_from(">6H", data, offset + 6 + 12 * j)
                platform, encoding, language, name_id, length, at = key
                # Windows, Unicode BMP, en-US, the copyright notice.
                if (platform, encoding, language, name_id) != (3, 1, 0x409, 0):
                    continue
                start = offset + strings + at
                if start + length > len(data):
                    raise Error(f"{path}: its copyright notice runs past the end")
                return data[start : start + length].decode("utf-16-be").strip()
    except (struct.error, UnicodeDecodeError) as e:
        raise Error(f"{path}: cannot read its name table: {e}") from None
    raise Error(f"{path} has no copyright notice for Windows in US English")


def _same(c: Component) -> Component:
    return c


def norm(path: str, what: str) -> str:
    """A path relative to the repository, normalized, with forward slashes.
    One that leaves the repository is an error."""
    out = posixpath.normpath(path.replace("\\", "/"))
    if out == ".." or out.startswith("../") or posixpath.isabs(out):
        raise Error(f"{what}: {path} is outside the repository")
    return out


def collect(
    repo: Path,
    report: dict[str, Any],
    dirs: dict[str, Any],
    overrides: dict[str, Any],
    tree: Path,
    fixed: list[Component],
) -> list[Component]:
    """The components of THIRD-PARTY-NOTICES.txt, sorted by name.

    `report` and `dirs` are windows-packages.json and
    windows-package-dirs.json, from a build run in `repo`; `overrides` is
    third-party.json; `tree` is the installed app; `fixed` are the
    toolchain's components."""
    where = {p["hash"]: p for p in dirs["packages"]}

    def directory(pkg_hash: str) -> Path:
        if pkg_hash not in where:
            raise Error(f"{pkg_hash}: in the report but not in the directories")
        d = Path(where[pkg_hash]["dir"])
        return d if d.is_absolute() else repo / d

    if directory("").resolve() != repo.resolve():
        raise Error(f"the report is for {directory('')}, not {repo}")

    def in_repo(pkg_hash: str) -> str | None:
        """A package's path in this repository, if it is one of its own: a
        path dependency's hash is its path."""
        if pkg_hash == "":
            return ""
        if directory(pkg_hash).resolve() == (repo / pkg_hash).resolve():
            return pkg_hash
        return None

    spdx: dict[str, dict[str, Any]] = {}
    for pkg in report["packages"]:
        for tp in pkg["third_party"]:
            old = spdx.setdefault(tp["name"], tp)
            if old["license"] != tp["license"]:
                raise Error(
                    f"{tp['name']}: two .third_party licenses, "
                    f"{old['license']!r} and {tp['license']!r}"
                )
    named = overrides.get("packages", {})
    versions = {pkg["hash"]: pkg["version"] for pkg in report["packages"]}

    found: dict[str, Component] = {}

    def add(c: Component) -> None:
        old = found.setdefault(c.name, c)
        if old is c:
            return
        old.license = old.license or c.license
        old.url = old.url or c.url
        old.note = old.note or c.note
        old.versions += [v for v in c.versions if v not in old.versions]
        old.texts += [t for t in c.texts if t not in old.texts]

    def described(name: str, root: Path, version: str | None) -> Component:
        """A package by name, its texts from third-party.json or else from
        the license files at `root`."""
        tp = spdx.get(name, {})
        o = named.get(name, {})
        check_keys(o, {"url", "note", "texts", "add"}, f"package {name}")
        c = Component(
            name, license=tp.get("license"), url=o.get("url") or tp.get("url")
        )
        if version or tp.get("version"):
            c.versions.append(version or tp["version"])
        c.note = o.get("note")
        if "texts" in o:
            c.texts = [text_of(repo, t, root) for t in o["texts"]]
        else:
            c.texts = license_files(root)
        c.texts += [text_of(repo, t, root) for t in o.get("add", [])]
        if not c.texts and not c.note:
            raise Error(
                f"{name}: no license file at the root of {root}; give its texts "
                f"in {OVERRIDES.name}, or a note saying why it has none"
            )
        return c

    def fetched(pkg_hash: str) -> Component:
        names = where[pkg_hash]["names"] if pkg_hash in where else []
        if not names:
            raise Error(f"{pkg_hash}: no build.zig.zon names this package")
        name = min(names, key=lambda n: (len(n), n))
        return described(name, directory(pkg_hash), versions.get(pkg_hash))

    # Vendored code: third-party.json's, and the `.third_party` entries
    # with a path in this repository. A package's texts are read only if
    # the app links it. Longest path first, so that the closest covers.
    covers: list[tuple[str, Callable[[], Component]]] = []
    vendored: dict[str, Component] = {}
    check_keys(overrides, {"vendored", "embedded", "packages", "installed"}, "the file")
    for v in overrides.get("vendored", []):
        check_keys(
            v, {"name", "path", "license", "url", "texts"}, f"vendored {v.get('name')}"
        )
        c = Component(v["name"], license=v.get("license"), url=v.get("url"))
        c.texts = [text_of(repo, t) for t in v["texts"]]
        if not c.texts:
            raise Error(f"{OVERRIDES.name}: vendored {v['name']} has no texts")
        vendored[c.name] = c
        covers.append((norm(v["path"], v["name"]), functools.partial(_same, c)))
    for pkg in report["packages"]:
        rel = in_repo(pkg["hash"])
        if rel is None:
            continue
        for tp in pkg["third_party"]:
            if tp["path"] is not None:
                path = norm(posixpath.join(rel, tp["path"]), tp["name"])
                # Vendored code takes the version of the build.zig.zon
                # that lists it, unless its entry sets its own.
                ver = tp.get("version") or pkg["version"]
                lazy = functools.cache(
                    lambda name=tp["name"], path=path, ver=ver: described(
                        name, repo / path, ver
                    )
                )
                covers.append((path, lazy))
    covers.sort(key=lambda c: len(c[0]), reverse=True)

    for pkg in report["packages"]:
        if not pkg["linked_paths"]:
            continue
        rel = in_repo(pkg["hash"])
        if rel is None:
            add(fetched(pkg["hash"]))
            continue
        for linked in pkg["linked_paths"]:
            path = norm(posixpath.join(rel, linked), pkg["hash"] or "ghostty")
            for cover, component in covers:
                if path == cover or path.startswith(cover + "/"):
                    add(component())
                    break
            else:
                if "vendor" in path.split("/"):
                    raise Error(
                        f"{path} is vendored code that {OVERRIDES.name} does not list"
                    )

    # Embedded files: the report lists modules and C sources, never a file
    # that @embedFile compiles in, so these are listed by hand and are in
    # every build. A listed file that is gone is an error, so that a
    # renamed one cannot leave a stale entry.
    for e in overrides.get("embedded", []):
        what = f"embedded {e.get('name')}"
        check_keys(e, {"name", "paths", "license", "url", "texts"}, what)
        if not e["paths"]:
            raise Error(f"{OVERRIDES.name}: {what} has no paths")
        c = Component(e["name"], license=e.get("license"), url=e.get("url"))
        notices = []
        for p in e["paths"]:
            file = repo / norm(p, e["name"])
            if not file.is_file():
                raise Error(f"{OVERRIDES.name}: {what}: {file} is missing")
            if file.suffix.lower() in FONTS:
                notices.append(font_copyright(file))
        c.texts = [text_of(repo, t) for t in e["texts"]]
        if not c.texts:
            raise Error(f"{OVERRIDES.name}: {what} has no texts")
        if notices:
            # The copyright lines differ from font to font, so they come
            # first and on their own, apart from a license text that
            # render() may print once for many parts.
            label = "Copyright notices in the fonts"
            c.texts.insert(0, (label, "\n".join(sorted(set(notices)))))
        add(c)

    # Installed files, from a fetched package or from vendored code. A
    # path that is not in the app is an error, so that a misspelt one
    # cannot drop a notice.
    by_name = {n: h for h, p in where.items() for n in p["names"]}
    for path, name in overrides.get("installed", {}).items():
        if name in vendored and name in by_name:
            raise Error(
                f"{OVERRIDES.name}: {name} names both a package and vendored code"
            )
        if name not in vendored and name not in by_name:
            raise Error(
                f"{OVERRIDES.name}: no package or vendored code is named {name}"
            )
        if not (tree / path).exists():
            raise Error(f"{OVERRIDES.name}: installed {path} is not in the app")
        add(vendored[name] if name in vendored else fetched(by_name[name]))

    for c in fixed:
        add(c)
    return sorted(found.values(), key=lambda c: c.name.casefold())


HEADER = """\
Ghostty for Windows includes the software below. Ghostty itself is under
the MIT license in LICENSE.txt. Each part below names its license, as an
SPDX expression where it is known, followed by the license texts it comes
with."""

RULE = "-" * 72


def render(components: list[Component]) -> str:
    """THIRD-PARTY-NOTICES.txt. A text that an earlier part has too is
    printed once."""
    out = [HEADER]
    seen: dict[str, str] = {}
    for c in components:
        title = c.name + (f" {', '.join(c.versions)}" if c.versions else "")
        out += ["", RULE, title]
        if c.license:
            out.append(f"License: {c.license}")
        if c.url:
            out.append(f"Source: {c.url}")
        if c.note:
            out.append(c.note)
        for label, text in c.texts:
            out += ["", f"{label}:"]
            if text in seen:
                out.append(f"The same text as {seen[text]} above.")
            else:
                seen[text] = f"{c.name}'s {label}"
                out += ["", text]
    return "\n".join(out) + "\n"


def pe_machine(path: Path) -> int | None:
    """A PE file's machine type, or None for a file that is not one."""
    with path.open("rb") as f:
        head = f.read(64)
        if len(head) < 64 or head[:2] != b"MZ":
            return None
        f.seek(int.from_bytes(head[0x3C:0x40], "little"))
        sig = f.read(6)
    if len(sig) < 6 or sig[:4] != b"PE\0\0":
        return None
    return int.from_bytes(sig[4:6], "little")


def check_tree(top: Path, arch: str) -> None:
    """Fails unless the installed app is what the zip should hold."""
    problems = []
    for dirpath, dirnames, filenames in os.walk(top):
        for name in dirnames + filenames:
            p = Path(dirpath, name)
            if p.is_symlink():
                problems.append(f"{p.relative_to(top).as_posix()} is a symbolic link")
    top_names = sorted(p.name for p in top.iterdir())
    if top_names != ["bin", "share"]:
        problems.append(f"the top holds {top_names}, not bin and share")
    if (top / "bin").is_dir():
        names = {p.name for p in (top / "bin").iterdir()}
        problems += [f"bin/{n} is missing" for n in sorted(BIN - names)]
        problems += [f"bin/{n} is not expected" for n in sorted(names - BIN)]
        for name in sorted(names & BIN):
            if name.endswith((".exe", ".com", ".dll")):
                machine = pe_machine(top / "bin" / name)
                if machine != ARCHES[arch]:
                    got = "not a PE file" if machine is None else f"{machine:#06x}"
                    problems.append(f"bin/{name} is {got}, not {arch}")
    for f in SHARE_FILES:
        if not (top / f).is_file():
            problems.append(f"{f} is missing")
    for d in SHARE_DIRS:
        if not (top / d).is_dir() or not any((top / d).iterdir()):
            problems.append(f"{d} is missing or empty")
    if problems:
        raise Error(
            "the build installed an unexpected tree:\n  " + "\n  ".join(problems)
        )


def files_under(top: Path, prefix: str) -> dict[str, Path]:
    """Every file under `top`, by its name in the zip."""
    out = {}
    for dirpath, _, filenames in os.walk(top):
        for name in filenames:
            p = Path(dirpath, name)
            out[f"{prefix}/{p.relative_to(top).as_posix()}"] = p
    return out


def write_zip(dest: Path, files: dict[str, Path | bytes], when: DateTime) -> None:
    """A zip of `files` (name to path or contents) whose bytes depend only
    on the names, the contents and `when`."""
    with zipfile.ZipFile(dest, "w") as zf:
        for name in sorted(files):
            src = files[name]
            data = src if isinstance(src, bytes) else src.read_bytes()
            info = zipfile.ZipInfo(name, when)
            # Made on MS-DOS (0), so the attributes are DOS ones: the
            # archive bit, which Windows sets on every file it writes.
            # zipfile would put Unix permissions in place of a zero.
            info.create_system = 0
            info.external_attr = 0x20
            zf.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def zip_time() -> DateTime:
    epoch = os.environ.get("SOURCE_DATE_EPOCH") or git("log", "-1", "--format=%ct")
    try:
        seconds = int(epoch)
    except ValueError:
        raise Error(
            f"SOURCE_DATE_EPOCH is {epoch!r}, not a number of seconds"
        ) from None
    t = time.gmtime(max(seconds, ZIP_EPOCH))
    return (t.tm_year, t.tm_mon, t.tm_mday, t.tm_hour, t.tm_min, t.tm_sec)


def git(*args: str) -> str:
    return run(["git", *args]).strip()


def run(cmd: list[str]) -> str:
    # zig and git print UTF-8; without UTF-8 mode, as on Windows before
    # Python 3.15, text=True would decode with the ANSI code page.
    try:
        return subprocess.run(
            cmd, cwd=REPO, check=True, capture_output=True, encoding="utf-8"
        ).stdout
    except subprocess.CalledProcessError as e:
        raise Error(f"{' '.join(cmd)} failed:\n{e.stderr}") from None


def zig_build(zig: str, args: list[str], prefix: Path) -> None:
    cmd = [zig, "build", *args, "--prefix", str(prefix)]
    print("+", " ".join(cmd), file=sys.stderr, flush=True)
    if subprocess.run(cmd, check=False, cwd=REPO).returncode != 0:
        raise Error("zig build failed")


def zig_license(zig: str, given: Path | None) -> Path:
    """Zig's LICENSE: beside zig in a release archive, one directory up in
    a Homebrew-style install."""
    exe = Path(zig).resolve()
    for p in (
        [given] if given else [exe.parent / "LICENSE", exe.parent.parent / "LICENSE"]
    ):
        if p.is_file() and "Copyright (c) Zig contributors" in read_text(p):
            return p
    raise Error(f"no Zig LICENSE beside {exe} or one directory up; pass --zig-license")


def zig_lib_dir(zig: str) -> Path:
    env = run([zig, "env"])
    m = re.search(r'^\s*\.lib_dir = "((?:[^"\\]|\\.)*)"', env, re.MULTILINE)
    if not m:
        raise Error("zig env names no .lib_dir")

    def unescape(e: re.Match[str]) -> str:
        if e.group(1) in '\\"':
            return str(e.group(1))
        raise Error(f"zig env: cannot read \\{e.group(1)} in {m.group(1)!r}")

    return Path(re.sub(r"\\(.)", unescape, m.group(1)))


def gdtoa(mingw: Path) -> Component:
    """gdtoa, David M. Gay's number conversion, which mingw-w64's printf
    and strtold link in. Each file carries its own copyright line above a
    permission notice and disclaimer that must appear in the
    documentation; COPYING sets such parts aside. A notice is printed
    once with every copyright line above it, and a file whose notice
    cannot be read is an error, so that a new Zig cannot drop one."""
    # A notice, wrapped as one line, to its text, files and copyrights.
    groups: dict[str, tuple[str, list[str], dict[str, None]]] = {}
    for f in sorted((mingw / "gdtoa").glob("*.[ch]")):
        text = read_text(f)
        lines = [ln.strip() for ln in text.split("\n")]
        copyrights = [ln for ln in lines if ln.startswith("Copyright (C)")]
        if not copyrights:
            # Generated headers carry no notice; any other file must.
            if "copyright" in text.lower():
                raise Error(f"{f}: no line starts with 'Copyright (C)'")
            continue
        notice = excerpt(text, "Permission to use", "SOFTWARE.", f.name)
        group = groups.setdefault(" ".join(notice.split()), (notice, [], {}))
        group[1].append(f.name)
        group[2].update(dict.fromkeys(copyrights))
    if not groups:
        raise Error(f"{mingw / 'gdtoa'} holds no gdtoa sources")
    texts = []
    # The notice most files share first, as plain "gdtoa".
    ordered = sorted(groups.values(), key=lambda g: (-len(g[1]), g[1]))
    for i, (notice, files, holders) in enumerate(ordered):
        label = "gdtoa" if i == 0 else f"gdtoa {', '.join(files)}"
        lines = sorted(holders) + ["All Rights Reserved", "", notice]
        texts.append((label, "\n".join(lines)))
    return Component(
        "gdtoa",
        note="Part of mingw-w64's C runtime, by David M. Gay.",
        texts=texts,
    )


def toolchain(zig: str, license_path: Path) -> list[Component]:
    lib = zig_lib_dir(zig) / "libc" / "mingw"
    mingw = lib / "COPYING"
    if not mingw.is_file():
        raise Error(f"{mingw} is missing")
    return [
        gdtoa(lib),
        Component(
            "Zig standard library and compiler_rt",
            license="MIT",
            versions=[run([zig, "version"]).strip()],
            url="https://ziglang.org",
            texts=[("LICENSE", read_text(license_path))],
        ),
        Component(
            "mingw-w64 C runtime",
            license="ZPL-2.1",
            url="https://www.mingw-w64.org",
            texts=[("COPYING", read_text(mingw))],
        ),
    ]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def make(args: argparse.Namespace) -> None:
    if not SEMVER.match(args.version):
        raise Error(f"{args.version!r} is not a semantic version")
    if not args.allow_dirty:
        dirty = git("status", "--porcelain", "--untracked-files=no")
        if dirty:
            raise Error(f"tracked files have changes (or pass --allow-dirty):\n{dirty}")
    zig = shutil.which(args.zig)
    if zig is None:
        raise Error(f"{args.zig} is not on PATH")
    fixed = toolchain(zig, zig_license(zig, args.zig_license))
    when = zip_time()
    name = f"ghostty-{args.version}-windows-{args.arch}"
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(dir=out, prefix=".stage-") as tmp:
        stage = Path(tmp)
        flags = [
            "-Dapp-runtime=windows",
            f"-Dtarget={args.arch}-windows-gnu",
            "-Doptimize=ReleaseFast",
            "-Dstrip=false",
            f"-Dversion-string={args.version}",
        ]
        zig_build(zig, ["windows-packages", *flags], stage / "report")
        top = stage / name
        zig_build(zig, flags, top)
        check_tree(top, args.arch)

        components = collect(
            REPO,
            json.loads((stage / "report" / "windows-packages.json").read_text("utf-8")),
            json.loads(
                (stage / "report" / "windows-package-dirs.json").read_text("utf-8")
            ),
            json.loads(OVERRIDES.read_text("utf-8")),
            top,
            fixed,
        )
        app: dict[str, Path | bytes] = {}
        pdb: dict[str, Path | bytes] = {}
        for zip_name, path in files_under(top, name).items():
            (pdb if zip_name.endswith(".pdb") else app)[zip_name] = path
        app[f"{name}/LICENSE.txt"] = REPO / "LICENSE"
        app[f"{name}/THIRD-PARTY-NOTICES.txt"] = render(components).encode("utf-8")

        done = []
        for dest, files in ((out / f"{name}.zip", app), (out / f"{name}-pdb.zip", pdb)):
            write_zip(stage / dest.name, files, when)
            os.replace(stage / dest.name, dest)
            done.append(dest)
    for dest in done:
        print(f"{sha256(dest)}  {dest.name}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build Ghostty's portable Windows zips."
    )
    parser.add_argument("--arch", required=True, choices=sorted(ARCHES))
    parser.add_argument(
        "--version", required=True, help="a semantic version, such as 1.4.1"
    )
    parser.add_argument("--out", type=Path, default=REPO / "zig-out" / "dist")
    parser.add_argument("--zig", default="zig", help="the zig to build with")
    parser.add_argument("--zig-license", type=Path, help="Zig's LICENSE, if not found")
    parser.add_argument(
        "--allow-dirty", action="store_true", help="build with uncommitted changes"
    )
    try:
        make(parser.parse_args(argv))
    except Error as e:
        print(f"make_zip: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
