"""
Tests for make_zip.py:

    python3 -I dist/windows/test_make_zip.py

The fixture repository mirrors the shapes `zig build windows-packages`
reports for the real app: Ghostty's own paths, vendored code reached from
two packages, a `.third_party` path, fetched packages linked, unlinked and
installed, and one with no license file.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from typing import Any

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
            ],
            "packages": {
                "bindings": {"note": "Generated from imgui's headers.", "texts": []},
                "conpty": {"texts": [{"file": "dist/windows/conpty-LICENSE.txt"}]},
            },
            "installed": {"bin/conpty.dll": "conpty", "share/ghostty/themes": "themes"},
        }
        write(self.tree / "bin/conpty.dll", pe(0x8664))
        self.fixed = [
            mz.Component("Zig", license="MIT", texts=[("LICENSE", "Zig MIT")])
        ]

    def collect(self) -> list[mz.Component]:
        return mz.collect(
            self.repo, self.report, self.dirs, self.overrides, self.tree, self.fixed
        )

    def by_name(self) -> dict[str, mz.Component]:
        return {c.name: c for c in self.collect()}

    def linked(self, pkg_hash: str) -> list[str]:
        for p in self.report["packages"]:
            if p["hash"] == pkg_hash:
                return p["linked_paths"]  # type: ignore[no-any-return]
        raise KeyError(pkg_hash)


class TestCollect(Fixture):
    def test_lists_what_is_linked_or_installed(self) -> None:
        # Not ghostty (its own paths), breakpad (fetched, not linked) or
        # themes (not installed); glad once, though two packages link it.
        self.assertEqual(
            [c.name for c in self.collect()],
            ["bindings", "conpty", "glad", "simdutf", "stb", "zf", "Zig", "zlib"],
        )

    def test_installed_package(self) -> None:
        write(self.tree / "share/ghostty/themes/Dark", "palette = 0=#000000\n")
        themes = self.by_name()["themes"]
        self.assertEqual(
            (themes.license, themes.texts), ("MIT", [("LICENSE", "themes MIT")])
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
        self.assertEqual(c["bindings"].note, "Generated from imgui's headers.")

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

        for change, error in [
            (unknown_key, r"package conpty has unknown keys \['text'\]"),
            (unknown_text_key, r"has unknown keys \['form'\]"),
            (unknown_vendored_key, r"vendored glad has unknown keys \['licence'\]"),
            (unknown_top_key, r"the file has unknown keys \['vendor'\]"),
            (package_file_in_vendored, "is not in a package"),
            (both_files, "names neither or both"),
            (missing_file, "dist/windows/gone.txt is missing"),
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
