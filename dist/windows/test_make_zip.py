"""
Tests for make_zip.py:

    python3 -I dist/windows/test_make_zip.py

The fixture repository mirrors the shapes `zig build windows-packages`
reports for the real app: Ghostty's own paths, vendored code reached from
two packages, a `.third_party` path, fetched packages linked, unlinked and
installed, and one with no license file.
"""

from __future__ import annotations

import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from typing import Any
from unittest import mock

# Import make_zip from beside this file, without leaving a __pycache__.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_zip as mz


def write(path: Path, data: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(data, bytes):
        path.write_bytes(data)
    else:
        path.write_text(data, "utf-8")


def tp(name: str, license: str, **kw: Any) -> dict[str, Any]:
    return {
        "name": name,
        "license": license,
        "version": None,
        "path": None,
        "url": None,
    } | kw


def package(
    hash: str,
    linked: list[str],
    third_party: list[dict[str, Any]] | None = None,
    version: str | None = None,
) -> dict[str, Any]:
    return {
        "hash": hash,
        "version": version,
        "linked_paths": linked,
        "third_party": third_party or [],
    }


def pe(machine: int) -> bytes:
    head = bytearray(64)
    head[:2] = b"MZ"
    head[0x3C:0x40] = (64).to_bytes(4, "little")
    return bytes(head) + b"PE\0\0" + machine.to_bytes(2, "little") + bytes(18)


def font(*records: tuple[int, int, int, int, str]) -> bytes:
    """A TrueType font that holds an OS/2 table that is not a name table,
    then a name table with these records: platform, encoding, language,
    name ID, text."""
    entries, strings = b"", b""
    for platform, encoding, language, name_id, text in records:
        data = text.encode("utf-16-be")
        entries += struct.pack(
            ">6H", platform, encoding, language, name_id, len(data), len(strings)
        )
        strings += data
    name = struct.pack(">HHH", 0, len(records), 6 + len(entries)) + entries + strings
    other = b"\xff" * 6
    head = struct.pack(">IHHHH", 0x00010000, 2, 0, 0, 0)
    at = len(head) + 2 * 16
    return (
        head
        + struct.pack(">4sIII", b"OS/2", 0, at, len(other))
        + struct.pack(">4sIII", b"name", 0, at + len(other), len(name))
        + other
        + name
    )


def copyright_font(text: str) -> bytes:
    # The Mac record, the German one and the family name are not it.
    return font(
        (1, 0, 0, 0, "Mac copyright"),
        (3, 1, 0x407, 0, "Urheberrecht"),
        (3, 1, 0x409, 1, "Family"),
        (3, 1, 0x409, 0, text),
    )


class Fixture(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name, "repo")
        self.tree = Path(tmp.name, "tree")
        self.tree.mkdir()
        r = self.repo

        write(r / "vendor/glad/LICENSE-APACHE", "Apache License\nVersion 2.0\n")
        write(
            r / "vendor/glad/include/KHR/khrplatform.h",
            "/*\n** Copyright (c) Khronos\n**\n** Permission is hereby granted\n"
            "** IN THE MATERIALS.\n*/\n#define KHR 1\n",
        )
        write(
            r / "src/stb/stb_image.h",
            "/* stb_image\n LICENSE\n This software is available under 2 licenses\n"
            " ALTERNATIVE A - MIT\n OTHER DEALINGS IN THE SOFTWARE.\n*/\nint x;\n",
        )
        write(r / "pkg/simdutf/vendor/LICENSE-MIT", "simdutf MIT\n")
        write(r / "dist/windows/conpty-LICENSE.txt", "conpty MIT\n")
        write(r / "src/shell/preexec.sh", "# preexec\n")
        write(r / "dist/windows/licenses/preexec-LICENSE.txt", "preexec MIT\n")
        write(r / "src/font/res/Emoji.ttf", copyright_font("Copyright 2022 B"))
        write(r / "src/font/res/Emoji-Text.ttf", copyright_font("Copyright 2013 A"))
        write(r / "src/font/res/Emoji-Bold.ttf", copyright_font("Copyright 2013 A"))
        write(r / "src/font/res/OFL.txt", "OFL text\n")
        fetched = {
            "N-V-zlib": (["zlib"], {"LICENSE": "zlib license\n"}),
            "N-V-breakpad": (["breakpad"], {}),
            "N-V-bindings": (["bindings"], {"README.md": "no license here\n"}),
            "N-V-conpty": (["conpty"], {}),
            "N-V-themes": (["themes"], {"LICENSE": "themes MIT\n"}),
            "zf-0.1.0-x": (
                ["zf_vaxis_zf", "zf"],
                {
                    "LICENSE.md": "zf MIT\n",
                    "license-checker.cfg": "not a license\n",
                    "AUTHORS": "someone\n",
                },
            ),
        }
        for h, (_, files) in fetched.items():
            (r / "zig-pkg" / h).mkdir(parents=True)
            for name, text in files.items():
                write(r / "zig-pkg" / h / name, text)

        self.report: dict[str, Any] = {
            "packages": [
                package(
                    "",
                    [
                        "src/main.zig",
                        "src",
                        "src/stb/stb.c",
                        "vendor/glad/include",
                        "vendor/glad/src/gl.c",
                    ],
                    [tp("themes", "MIT")],
                    "1.4.1-dev",
                ),
                package("pkg/opengl", ["main.zig", "../../vendor/glad/include"]),
                package(
                    "pkg/simdutf",
                    ["vendor", "vendor/simdutf.cpp"],
                    [tp("simdutf", "Apache-2.0 OR MIT", path="vendor")],
                    "9.0.0",
                ),
                package("pkg/zlib", [], [tp("zlib", "Zlib", version="1.3.1")]),
                package("N-V-zlib", ["adler32.c"]),
                package("N-V-breakpad", []),
                package("N-V-bindings", ["dcimgui.cpp"]),
                package("N-V-conpty", []),
                package("N-V-themes", []),
                package("zf-0.1.0-x", ["src/zf.zig"], version="0.1.0"),
            ]
        }
        self.dirs: dict[str, Any] = {
            "packages": [{"hash": "", "dir": str(r), "names": []}]
            + [
                {"hash": h, "dir": h, "names": [h.removeprefix("pkg/")]}
                for h in ("pkg/opengl", "pkg/simdutf", "pkg/zlib")
            ]
            + [
                {"hash": h, "dir": f"zig-pkg/{h}", "names": n}
                for h, (n, _) in fetched.items()
            ]
        }
        self.overrides: dict[str, Any] = {
            "vendored": [
                {
                    "name": "glad",
                    "path": "vendor/glad",
                    "license": "(WTFPL OR CC0-1.0) AND Apache-2.0",
                    "texts": [
                        {"file": "vendor/glad/LICENSE-APACHE"},
                        {
                            "file": "vendor/glad/include/KHR/khrplatform.h",
                            "from": "Copyright (c) Khronos",
                            "to": "IN THE MATERIALS.",
                        },
                    ],
                },
                {
                    "name": "stb",
                    "path": "src/stb",
                    "license": "MIT OR Unlicense",
                    "texts": [
                        {
                            "file": "src/stb/stb_image.h",
                            "from": "available under 2 licenses",
                            "to": "OTHER DEALINGS IN THE SOFTWARE.",
                        }
                    ],
                },
                {
                    "name": "preexec",
                    "path": "src/shell/preexec.sh",
                    "texts": [{"file": "dist/windows/licenses/preexec-LICENSE.txt"}],
                },
            ],
            "embedded": [
                {
                    "name": "Noto",
                    "paths": [
                        "src/font/res/Emoji.ttf",
                        "src/font/res/Emoji-Text.ttf",
                        "src/font/res/Emoji-Bold.ttf",
                    ],
                    "license": "OFL-1.1",
                    "texts": [{"file": "src/font/res/OFL.txt"}],
                }
            ],
            "packages": {
                "bindings": {"note": "Generated from imgui's headers.", "texts": []},
                "conpty": {"texts": [{"file": "dist/windows/conpty-LICENSE.txt"}]},
            },
            "installed": {
                "bin/conpty.dll": "conpty",
                "share/ghostty/themes": "themes",
                "share/ghostty/shell/preexec.sh": "preexec",
            },
        }
        write(self.tree / "bin/conpty.dll", pe(0x8664))
        write(self.tree / "share/ghostty/themes/Dark", "palette = 0=#000000\n")
        write(self.tree / "share/ghostty/shell/preexec.sh", "# preexec\n")
        self.fixed = [
            mz.Component("Zig", license="MIT", texts=[("LICENSE", "Zig MIT")])
        ]

    def collect(self) -> list[mz.Component]:
        return mz.collect(
            self.repo, self.report, self.dirs, self.overrides, self.tree, self.fixed
        )

    def by_name(self) -> dict[str, mz.Component]:
        return {c.name: c for c in self.collect()}

    def package(self, pkg_hash: str) -> dict[str, Any]:
        for p in self.report["packages"]:
            if p["hash"] == pkg_hash:
                return p  # type: ignore[no-any-return]
        raise KeyError(pkg_hash)

    def linked(self, pkg_hash: str) -> list[str]:
        return self.package(pkg_hash)["linked_paths"]  # type: ignore[no-any-return]


class TestCollect(Fixture):
    def test_lists_what_is_linked_or_installed(self) -> None:
        # Not ghostty (its own paths) or breakpad (fetched, not linked);
        # glad once, though two packages link it.
        self.assertEqual(
            [c.name for c in self.collect()],
            [
                "bindings",
                "conpty",
                "glad",
                "Noto",
                "preexec",
                "simdutf",
                "stb",
                "themes",
                "zf",
                "Zig",
                "zlib",
            ],
        )

    def test_embedded_files(self) -> None:
        # Each font's own copyright line, once, ahead of the license.
        self.assertEqual(
            self.by_name()["Noto"].texts,
            [
                (
                    "Copyright notices in the fonts",
                    "Copyright 2013 A\nCopyright 2022 B",
                ),
                ("OFL.txt", "OFL text"),
            ],
        )

    def test_installed_package(self) -> None:
        themes = self.by_name()["themes"]
        self.assertEqual(
            (themes.license, themes.texts), ("MIT", [("LICENSE", "themes MIT")])
        )

    def test_installed_vendored_code(self) -> None:
        # Installed, never linked, so only `installed` can list it.
        self.assertEqual(
            self.by_name()["preexec"].texts, [("preexec-LICENSE.txt", "preexec MIT")]
        )

    def test_fetched_package(self) -> None:
        c = self.by_name()
        # The license and version come from pkg/zlib's `.third_party`.
        self.assertEqual(
            (c["zlib"].license, c["zlib"].versions, c["zlib"].texts),
            ("Zlib", ["1.3.1"], [("LICENSE", "zlib license")]),
        )
        # The shortest name; the report's version; only license files.
        self.assertEqual(
            (c["zf"].versions, c["zf"].texts), (["0.1.0"], [("LICENSE.md", "zf MIT")])
        )

    def test_vendored_texts(self) -> None:
        c = self.by_name()
        self.assertEqual(
            c["glad"].texts,
            [
                ("LICENSE-APACHE", "Apache License\nVersion 2.0"),
                (
                    "khrplatform.h (excerpt)",
                    (
                        "** Copyright (c) Khronos\n**\n** Permission is hereby granted\n"
                        "** IN THE MATERIALS."
                    ),
                ),
            ],
        )
        self.assertEqual(
            c["simdutf"].texts,
            [("LICENSE-MIT", "simdutf MIT")],
            "a .third_party path's files",
        )
        self.assertEqual(c["simdutf"].versions, ["9.0.0"], "its build.zig.zon's")
        self.assertEqual(c["bindings"].note, "Generated from imgui's headers.")

    def test_vendored_version_of_its_own(self) -> None:
        (simdutf,) = self.package("pkg/simdutf")["third_party"]
        simdutf["version"] = "8.0.0"
        self.assertEqual(self.by_name()["simdutf"].versions, ["8.0.0"])

    def test_closest_vendored_path_covers(self) -> None:
        write(self.repo / "src/stb/deep/LICENSE", "deep\n")
        self.overrides["vendored"].append(
            {
                "name": "deep",
                "path": "src/stb/deep",
                "texts": [{"file": "src/stb/deep/LICENSE"}],
            }
        )
        self.linked("").append("src/stb/deep/d.c")
        self.assertIn("deep", self.by_name())

    def test_unlisted_vendored_code_fails(self) -> None:
        for pkg, path, shown in [
            ("", "vendor/new/x.c", "vendor/new/x.c"),
            ("pkg/opengl", "../../vendor/other/a.h", "vendor/other/a.h"),
            ("pkg/simdutf", "../../src/vendor/b.c", "src/vendor/b.c"),
        ]:
            with self.subTest(path=path):
                self.linked(pkg).append(path)
                with self.assertRaisesRegex(mz.Error, f"^{shown} is vendored code"):
                    self.collect()
                self.linked(pkg).pop()

    def test_path_outside_the_repository_fails(self) -> None:
        self.linked("pkg/opengl").append("../../../elsewhere/x.h")
        with self.assertRaisesRegex(mz.Error, "outside the repository"):
            self.collect()

    def test_linked_package_without_license_fails(self) -> None:
        del self.overrides["packages"]["bindings"]
        with self.assertRaisesRegex(mz.Error, "^bindings: no license file"):
            self.collect()

    def test_override_needs_texts_or_note(self) -> None:
        del self.overrides["packages"]["bindings"]["note"]
        with self.assertRaisesRegex(mz.Error, "^bindings: no license file.* or a note"):
            self.collect()

    def test_reuse_licenses_folder(self) -> None:
        write(self.repo / "zig-pkg/N-V-zlib/LICENSES/MIT.txt", "MIT text\n")
        write(self.repo / "zig-pkg/N-V-zlib/LICENSES/Apache-2.0.txt", "Apache text\n")
        self.assertEqual(
            self.by_name()["zlib"].texts,
            [
                ("LICENSE", "zlib license"),
                ("LICENSES/Apache-2.0.txt", "Apache text"),
                ("LICENSES/MIT.txt", "MIT text"),
            ],
        )

    def test_added_texts(self) -> None:
        write(self.repo / "zig-pkg/N-V-zlib/docs/FTL.TXT", "intro\nFTL\nbody\nend\n")
        write(self.repo / "dist/windows/licenses/extra.txt", "extra\n")
        self.overrides["packages"]["zlib"] = {
            "add": [
                {"package_file": "docs/FTL.TXT", "from": "FTL", "to": "body"},
                {"file": "dist/windows/licenses/extra.txt"},
            ]
        }
        self.assertEqual(
            self.by_name()["zlib"].texts,
            [
                ("LICENSE", "zlib license"),
                ("docs/FTL.TXT (excerpt)", "FTL\nbody"),
                ("extra.txt", "extra"),
            ],
        )

    def test_bad_overrides_fail(self) -> None:
        def unknown_key(o: dict[str, Any]) -> None:
            o["packages"]["conpty"]["text"] = o["packages"]["conpty"].pop("texts")

        def unknown_text_key(o: dict[str, Any]) -> None:
            o["packages"]["conpty"]["texts"][0]["form"] = "x"

        def unknown_vendored_key(o: dict[str, Any]) -> None:
            o["vendored"][0]["licence"] = "MIT"

        def unknown_top_key(o: dict[str, Any]) -> None:
            o["vendor"] = []

        def package_file_in_vendored(o: dict[str, Any]) -> None:
            o["vendored"][0]["texts"] = [{"package_file": "LICENSE"}]

        def both_files(o: dict[str, Any]) -> None:
            o["packages"]["conpty"]["texts"][0]["package_file"] = "LICENSE"

        def missing_file(o: dict[str, Any]) -> None:
            o["packages"]["conpty"]["texts"][0]["file"] = "dist/windows/gone.txt"

        def unknown_embedded_key(o: dict[str, Any]) -> None:
            o["embedded"][0]["note"] = "x"

        def embedded_file_gone(o: dict[str, Any]) -> None:
            o["embedded"][0]["paths"].append("src/font/res/Gone.ttf")

        def embedded_outside(o: dict[str, Any]) -> None:
            o["embedded"][0]["paths"].append("../Elsewhere.ttf")

        def no_embedded_paths(o: dict[str, Any]) -> None:
            o["embedded"][0]["paths"] = []

        def no_embedded_texts(o: dict[str, Any]) -> None:
            o["embedded"][0]["texts"] = []

        def installed_path_misspelt(o: dict[str, Any]) -> None:
            o["installed"]["share/ghostty/shel/preexec.sh"] = "preexec"

        def installed_name_unknown(o: dict[str, Any]) -> None:
            o["installed"]["bin/conpty.dll"] = "conptyy"

        def installed_name_ambiguous(o: dict[str, Any]) -> None:
            o["vendored"][2]["name"] = "themes"
            o["installed"]["share/ghostty/shell/preexec.sh"] = "themes"

        for change, error in [
            (unknown_key, r"package conpty has unknown keys \['text'\]"),
            (unknown_text_key, r"has unknown keys \['form'\]"),
            (unknown_vendored_key, r"vendored glad has unknown keys \['licence'\]"),
            (unknown_top_key, r"the file has unknown keys \['vendor'\]"),
            (package_file_in_vendored, "is not in a package"),
            (both_files, "names neither or both"),
            (missing_file, "dist/windows/gone.txt is missing"),
            (unknown_embedded_key, r"embedded Noto has unknown keys \['note'\]"),
            (embedded_file_gone, "embedded Noto: .*Gone.ttf is missing"),
            (embedded_outside, "outside the repository"),
            (no_embedded_paths, "embedded Noto has no paths"),
            (no_embedded_texts, "embedded Noto has no texts"),
            (
                installed_path_misspelt,
                "installed share/ghostty/shel/preexec.sh is not in the app",
            ),
            (installed_name_unknown, "no package or vendored code is named conptyy"),
            (installed_name_ambiguous, "themes names both a package and vendored code"),
        ]:
            with self.subTest(change=change.__name__):
                self.setUp()
                change(self.overrides)
                with self.assertRaisesRegex(mz.Error, error):
                    self.collect()

    def test_missing_excerpt_marker_fails(self) -> None:
        self.overrides["vendored"][1]["texts"][0]["to"] = "NOT THERE"
        with self.assertRaisesRegex(mz.Error, "no line from .* contains 'NOT THERE'"):
            self.collect()

    def test_excerpt_needs_both_markers(self) -> None:
        del self.overrides["vendored"][1]["texts"][0]["to"]
        with self.assertRaisesRegex(mz.Error, "needs both 'from' and 'to'"):
            self.collect()

    def test_conflicting_licenses_fail(self) -> None:
        self.report["packages"][1]["third_party"] = [tp("zlib", "MIT")]
        with self.assertRaisesRegex(mz.Error, "two .third_party licenses"):
            self.collect()

    def test_report_for_another_checkout_fails(self) -> None:
        self.dirs["packages"][0]["dir"] = str(self.repo.parent)
        with self.assertRaisesRegex(mz.Error, "the report is for"):
            self.collect()


class TestText(unittest.TestCase):
    def test_read_text(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            for data, want in [
                (b"\xef\xbb\xbf\r\nA  \r\nB\t\r\n\r\n", "A\nB"),
                (b"\xef\xbb\xbfA\rB", "A\nB"),
                (b"Copyright \xa9 X\n", "Copyright © X"),
            ]:
                with self.subTest(data=data):
                    p = Path(tmp, "t")
                    p.write_bytes(data)
                    self.assertEqual(mz.read_text(p), want)

    def test_excerpt(self) -> None:
        text = "END\nSTART here\nmiddle\nEND there\nafter"
        self.assertEqual(
            mz.excerpt(text, "START", "END", "f"), "START here\nmiddle\nEND there"
        )
        self.assertEqual(mz.excerpt(text, "START", "START", "f"), "START here")
        with self.assertRaisesRegex(mz.Error, "no line contains 'GONE'"):
            mz.excerpt(text, "GONE", "END", "f")

    def test_font_copyright(self) -> None:
        good = copyright_font("Copyright 2013 A")
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp, "f.ttf")
            p.write_bytes(good)
            self.assertEqual(mz.font_copyright(p), "Copyright 2013 A")
            for data, error in [
                (b"PK\3\4" + bytes(40), "is not a TrueType or OpenType font"),
                (font((1, 0, 0, 0, "Mac only")), "has no copyright notice"),
                (good[:-1], "runs past the end"),
                (b"\0\1\0\0\0\1" + bytes(6), "cannot read its name table"),
            ]:
                with self.subTest(error=error):
                    p.write_bytes(data)
                    with self.assertRaisesRegex(mz.Error, error):
                        mz.font_copyright(p)

    def test_license_file_names(self) -> None:
        for name in [
            "LICENSE",
            "LICENSE.TXT",
            "LICENSE.md",
            "LICENSE-BSD3",
            "licence.rst",
            "COPYING",
            "NOTICE",
            "UNLICENSE",
            "OFL.txt",
            "LICENSE-APACHE",
        ]:
            self.assertTrue(mz.LICENSE_FILE.match(name), name)
        for name in [
            "license-checker.cfg",
            "LICENSES",
            "AUTHORS",
            "LICENSE.cfg",
            "COPYING.LIB.c",
            "README",
            "LICENSE-.txt",
            "xLICENSE",
        ]:
            self.assertFalse(mz.LICENSE_FILE.match(name), name)

    def test_render_prints_a_text_once(self) -> None:
        out = mz.render(
            [
                mz.Component(
                    "a",
                    license="MIT",
                    versions=["1.0"],
                    url="https://a",
                    texts=[("LICENSE", "SHARED")],
                ),
                mz.Component(
                    "b",
                    note="A note.",
                    texts=[("COPYING", "SHARED"), ("N", "other")],
                ),
            ]
        )
        self.assertEqual(out.count("SHARED"), 1)
        self.assertIn(
            "a 1.0\nLicense: MIT\nSource: https://a\n\nLICENSE:\n\nSHARED\n", out
        )
        self.assertIn(
            "b\nA note.\n\nCOPYING:\nThe same text as a's LICENSE above.\n\nN:\n\nother\n",
            out,
        )
        self.assertTrue(out.endswith("other\n"))


LUCENT = """\
Permission to use, copy, modify, and distribute this software and
its documentation, provided that this notice and warranty disclaimer
appear in supporting documentation.

LUCENT DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE."""


class TestToolchain(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.lib = Path(tmp.name, "lib")
        self.mingw = self.lib / "libc/mingw"
        g = self.mingw / "gdtoa"
        write(self.mingw / "COPYING", "ZPL\n")
        write(
            g / "gdtoa.c",
            "/***\nThe author of this software is David M. Gay.\n\n"
            "Copyright (C) 1998, 1999 by Lucent Technologies\nAll Rights Reserved\n\n"
            f"{LUCENT}\n\n***/\nint gdtoa;\n",
        )
        # The same notice wrapped another way, under another copyright.
        write(
            g / "strtodnrp.c",
            "/***\n  Copyright (C) 2004 by David M. Gay.\nBased on Lucent's.\n\n"
            f"{' '.join(LUCENT.split(chr(10) + chr(10))[0].split())}\n\n"
            f"{LUCENT.split(chr(10) + chr(10))[1]}\n***/\n",
        )
        write(
            g / "qnan.c",
            "/*\nCopyright (C) 2005 by David M. Gay\n"
            "Permission to use this. THE AUTHOR DISCLAIMS\nTHIS SOFTWARE.\n*/\n",
        )
        # Enough copyright lines that a set's order is not sorted by luck.
        for name, years in [
            ("dmisc.c", "1998"),
            ("hd_init.c", "2000"),
            ("strtodg.c", "1998-2001"),
            ("ulp.c", "1997, 1998"),
        ]:
            write(
                g / name,
                f"/***\nCopyright (C) {years} by Lucent Technologies\n\n{LUCENT}\n***/\n",
            )
        write(g / "gd_arith.h", "#define IEEE_8087\n")
        write(self.lib / "LICENSE", "Copyright (c) Zig contributors\n")

    def test_gdtoa(self) -> None:
        c = mz.gdtoa(self.mingw)
        self.assertEqual(
            c.texts,
            [
                (
                    "gdtoa",
                    (
                        "Copyright (C) 1997, 1998 by Lucent Technologies\n"
                        "Copyright (C) 1998 by Lucent Technologies\n"
                        "Copyright (C) 1998, 1999 by Lucent Technologies\n"
                        "Copyright (C) 1998-2001 by Lucent Technologies\n"
                        "Copyright (C) 2000 by Lucent Technologies\n"
                        "Copyright (C) 2004 by David M. Gay.\n"
                        f"All Rights Reserved\n\n{LUCENT}"
                    ),
                ),
                (
                    "gdtoa qnan.c",
                    (
                        "Copyright (C) 2005 by David M. Gay\nAll Rights Reserved\n\n"
                        "Permission to use this. THE AUTHOR DISCLAIMS\nTHIS SOFTWARE."
                    ),
                ),
            ],
        )

    def test_gdtoa_fails_closed(self) -> None:
        for text, error in [
            ("/*\nCopyright (C) 1998 Lucent\n*/\n", "misc.c: no line contains 'Perm"),
            ("/* Copyright (C) 1998 Lucent */\n", "misc.c: no line starts with 'Copy"),
        ]:
            with self.subTest(error=error):
                write(self.mingw / "gdtoa/misc.c", text)
                with self.assertRaisesRegex(mz.Error, error):
                    mz.gdtoa(self.mingw)
        for f in (self.mingw / "gdtoa").iterdir():
            f.unlink()
        with self.assertRaisesRegex(mz.Error, "holds no gdtoa sources"):
            mz.gdtoa(self.mingw)

    def test_toolchain(self) -> None:
        with (
            mock.patch.object(mz, "zig_lib_dir", return_value=self.lib),
            mock.patch.object(mz, "run", return_value="0.17.0\n"),
        ):
            parts = mz.toolchain("zig", self.lib / "LICENSE")
        self.assertEqual(
            [(c.name, c.texts[0][0]) for c in parts],
            [
                ("gdtoa", "gdtoa"),
                ("Zig standard library and compiler_rt", "LICENSE"),
                ("mingw-w64 C runtime", "COPYING"),
            ],
        )


class TestRepository(unittest.TestCase):
    """Checks of this repository's own files, not of make_zip."""

    def test_embedded_fonts_are_listed(self) -> None:
        # The package report cannot see @embedFile, so a font that
        # embedded.zig starts shipping must be added to third-party.json.
        src = (mz.REPO / "src/font/embedded.zig").read_text("utf-8")
        shipped, marker, _ = src.partition("// Fonts below are ONLY used for testing.")
        self.assertTrue(marker, "embedded.zig no longer marks its test fonts")
        embeds = {
            f"src/font/{p}" for p in re.findall(r'@embedFile\("(res/[^"]+)"\)', shipped)
        }
        self.assertTrue(embeds)
        overrides = json.loads(mz.OVERRIDES.read_text("utf-8"))
        listed = {p for e in overrides.get("embedded", []) for p in e["paths"]}
        self.assertEqual(embeds - listed, set())


class TestTree(unittest.TestCase):
    def make_tree(self, top: Path) -> None:
        for name in mz.BIN:
            write(
                top / "bin" / name,
                pe(0x8664) if name.endswith((".exe", ".com", ".dll")) else "x",
            )
        write(top / "share/terminfo/ghostty.terminfo", "ghostty|Ghostty,\n")
        write(top / "share/ghostty/shell-integration/bash/ghostty.bash", "#\n")
        write(top / "share/ghostty/themes/Dark", "#\n")

    def test_checks(self) -> None:
        def stray_top(t: Path) -> None:
            write(t / "README", "x")

        def stray_bin(t: Path) -> None:
            write(t / "bin/extra.dll", pe(0x8664))

        def missing(t: Path) -> None:
            (t / "bin/conpty.dll").unlink()

        def link(t: Path) -> None:
            (t / "share/ghostty/themes/Link").symlink_to("Dark")

        def arm(t: Path) -> None:
            write(t / "bin/OpenConsole.exe", pe(0xAA64))

        def not_pe(t: Path) -> None:
            write(t / "bin/ghostty.com", "MZ")

        def empty(t: Path) -> None:
            (t / "share/ghostty/themes/Dark").unlink()

        def terminfo(t: Path) -> None:
            (t / "share/terminfo/ghostty.terminfo").unlink()

        with tempfile.TemporaryDirectory() as tmp:
            self.make_tree(Path(tmp))
            mz.check_tree(Path(tmp), "x86_64")

        cases = [
            (stray_top, r"the top holds \['README', 'bin', 'share'\]"),
            (stray_bin, "bin/extra.dll is not expected"),
            (missing, "bin/conpty.dll is missing"),
            (link, "share/ghostty/themes/Link is a symbolic link"),
            (arm, "bin/OpenConsole.exe is 0xaa64, not x86_64"),
            (not_pe, "bin/ghostty.com is not a PE file"),
            (empty, "share/ghostty/themes is missing or empty"),
            (terminfo, "share/terminfo/ghostty.terminfo is missing"),
        ]
        for change, error in cases:
            with (
                self.subTest(change=change.__name__),
                tempfile.TemporaryDirectory() as tmp,
            ):
                top = Path(tmp)
                self.make_tree(top)
                change(top)
                with self.assertRaisesRegex(mz.Error, error):
                    mz.check_tree(top, "x86_64")

    def test_arch(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            self.make_tree(Path(tmp))
            with self.assertRaisesRegex(
                mz.Error, "bin/ghostty.exe is 0x8664, not aarch64"
            ):
                mz.check_tree(Path(tmp), "aarch64")


class TestZip(unittest.TestCase):
    def test_reproducible(self) -> None:
        when = (2026, 11, 9, 12, 30, 44)
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp, "src")
            write(src / "b", "bee")
            write(src / "a", b"\x00ay")
            files: dict[str, Path | bytes] = {
                "top/bin/b": src / "b",
                "top/a": src / "a",
                "top/N.txt": b"notices",
            }
            one, two = Path(tmp, "1.zip"), Path(tmp, "2.zip")
            mz.write_zip(one, files, when)
            # The same files in another order, from new copies.
            write(src / "c", "bee")
            mz.write_zip(
                two,
                {"top/N.txt": b"notices", "top/a": src / "a", "top/bin/b": src / "c"},
                when,
            )
            self.assertEqual(one.read_bytes(), two.read_bytes())

            with zipfile.ZipFile(one) as zf:
                infos = zf.infolist()
                self.assertEqual(
                    [i.filename for i in infos], ["top/N.txt", "top/a", "top/bin/b"]
                )
                for i in infos:
                    self.assertEqual(
                        (
                            i.date_time,
                            i.create_system,
                            i.external_attr,
                            i.compress_type,
                        ),
                        (when, 0, 0x20, zipfile.ZIP_DEFLATED),
                    )
                self.assertEqual(zf.read("top/a"), b"\x00ay")
                self.assertEqual(zf.read("top/bin/b"), b"bee")

    def test_zip_time(self) -> None:
        import os

        old = os.environ.get("SOURCE_DATE_EPOCH")
        self.addCleanup(
            lambda: (
                os.environ.__setitem__("SOURCE_DATE_EPOCH", old)
                if old
                else os.environ.pop("SOURCE_DATE_EPOCH", None)
            )
        )
        for value, want in [
            ("1762691444", (2025, 11, 9, 12, 30, 44)),
            ("0", (1980, 1, 1, 0, 0, 0)),
        ]:
            os.environ["SOURCE_DATE_EPOCH"] = value
            self.assertEqual(mz.zip_time(), want)
        os.environ["SOURCE_DATE_EPOCH"] = "soon"
        with self.assertRaisesRegex(mz.Error, "not a number"):
            mz.zip_time()


class TestCheckout(unittest.TestCase):
    """make()'s checks on the checkout, against a real git repository.
    A zig that is not on PATH stops make() just after them."""

    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.repo = Path(tmp.name)
        self.enterContext(mock.patch.object(mz, "REPO", self.repo))
        self.enterContext(
            mock.patch.dict(
                os.environ,
                {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"},
            )
        )
        write(self.repo / ".gitignore", "zig-out/\n.DS_Store\n")
        write(self.repo / "src/shell-integration/bash/ghostty.bash", "bash\n")
        for cmd in [
            ["init", "-q"],
            ["add", "."],
            [
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@example.com",
                "commit",
                "-qm",
                "t",
            ],
        ]:
            subprocess.run(["git", *cmd], cwd=self.repo, check=True)
        # The build's own output: ignored, outside src/shell-integration.
        write(self.repo / "zig-out/bin/ghostty.exe", "exe")

    def make(self, *extra: str) -> str:
        import contextlib
        import io

        err = io.StringIO()
        argv = ["--arch", "x86_64", "--version", "1.4.1", "--zig", "no-such-zig"]
        with contextlib.redirect_stderr(err):
            self.assertEqual(mz.main([*argv, *extra]), 1)
        return err.getvalue()

    def test_clean(self) -> None:
        self.assertEqual(self.make(), "make_zip: no-such-zig is not on PATH\n")

    def test_files_git_does_not_track(self) -> None:
        # Untracked, in a directory git does not track, and ignored.
        for path in ["bash/scratch.sh", "nu/new/x.nu", ".DS_Store"]:
            with self.subTest(path):
                stray = self.repo / "src/shell-integration" / path
                write(stray, "stray")
                try:
                    self.assertIn(f"src/shell-integration/{path}", self.make())
                    self.assertIn("not on PATH", self.make("--allow-dirty"))
                finally:
                    stray.unlink()

    def test_tracked_change(self) -> None:
        write(self.repo / "src/shell-integration/bash/ghostty.bash", "changed\n")
        self.assertRegex(self.make(), "tracked files have changes")


class TestRun(unittest.TestCase):
    def test_reads_utf8_whatever_the_locale(self) -> None:
        # A Python without UTF-8 mode on a Windows code page, running a
        # child that prints "Jörg" in UTF-8, as zig prints a path.
        code = "\n".join(
            [
                "import locale, sys",
                f"sys.path.insert(0, {str(Path(mz.__file__).parent)!r})",
                "locale.getencoding = lambda: 'cp1252'",
                "import make_zip",
                "child = 'import sys; sys.stdout.buffer.write(bytes([74, 195, 182, 114, 103]))'",
                "print(ascii(make_zip.run([sys.executable, '-I', '-c', child])))",
            ]
        )
        out = subprocess.run(
            [sys.executable, "-I", "-B", "-X", "utf8=0", "-c", code],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        self.assertEqual(out.strip(), ascii("J\u00f6rg"))


class TestArguments(unittest.TestCase):
    def test_versions(self) -> None:
        for v in ["1.4.1", "1.4.1-dev", "0.0.0", "1.4.1-rc.1+abc.5", "10.20.30"]:
            self.assertTrue(mz.SEMVER.match(v), v)
        for v in [
            "1.4",
            "v1.4.1",
            "01.4.1",
            "1.4.1-",
            "1.4.1/x",
            "1.4.1-a/../b",
            "1.4.1 ",
            "１.4.1",
        ]:
            self.assertFalse(mz.SEMVER.match(v), v)

    def test_bad_version_stops_before_building(self) -> None:
        import contextlib
        import io

        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertEqual(mz.main(["--arch", "x86_64", "--version", "1.4"]), 1)
        self.assertEqual(err.getvalue(), "make_zip: '1.4' is not a semantic version\n")


if __name__ == "__main__":
    unittest.main()
