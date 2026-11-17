"""
Tests for make_feed.py and make_winget.py:

    python3 -I dist/windows/test_make_feed.py

The winget tests build a package for real, as test_make_msi.py does, so
they need msitools and fail without it. Whether Ghostty accepts the feed
is tested against update_feed.zig's own rules (`allowed`), restated
here and checked against its source, not by running it.
"""

from __future__ import annotations

import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_feed as mf
import make_msi as mm
import make_winget as mw
import make_zip as mz
import test_make_msi as tmm

REPO = Path(__file__).resolve().parents[2]
TAG = "v1.4.1-win.3"


def run(main, argv: list[str]) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = main(argv)
    return code, out.getvalue(), err.getvalue()


def ghostty_allows(url: str, under: str, suffix: str) -> bool:
    """update_feed.zig's `allowed`, for the URLs a feed gives."""
    if not url.startswith(mf.RELEASES + under):
        return False
    path = url[len(mf.RELEASES + under) :]
    if not path or not path.endswith(suffix):
        return False
    return all(
        seg and seg not in (".", "..") and re.fullmatch(r"[A-Za-z0-9._+-]+", seg)
        for seg in path.split("/")
    )


class Temp(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name).resolve()

    def package(self, name: str, body: bytes = b"msi") -> Path:
        path = self.dir / name
        path.write_bytes(body)
        return path


class TestFeed(Temp):
    def test_names_each_package_by_its_asset_url_and_hash(self) -> None:
        arm = self.package("ghostty-1.4.1-win.3-windows-aarch64.msi", b"arm")
        x64 = self.package("ghostty-1.4.1-win.3-windows-x86_64.msi", b"x64")
        code, out, err = run(mf.main, [str(arm), str(x64), "--tag", TAG])
        self.assertEqual((code, err), (0, ""))
        dest = self.dir / mf.FEED
        self.assertEqual(out, f"{dest}\n")
        feed = json.loads(dest.read_text("utf-8"))
        releases = "https://github.com/Pyre909/ghostty/releases/"
        self.assertEqual(
            feed,
            {
                "version": "1.4.1-win.3",
                "notes": f"{releases}tag/{TAG}",
                "packages": {
                    "x86_64": {
                        "url": f"{releases}download/{TAG}/{x64.name}",
                        "sha256": mz.sha256(x64),
                    },
                    "aarch64": {
                        "url": f"{releases}download/{TAG}/{arm.name}",
                        "sha256": mz.sha256(arm),
                    },
                },
            },
        )
        # Every URL is one Ghostty accepts.
        self.assertTrue(ghostty_allows(feed["notes"], "", ""))
        for p in feed["packages"].values():
            self.assertTrue(ghostty_allows(p["url"], "download/", ".msi"))
            self.assertRegex(p["sha256"], r"\A[0-9a-f]{64}\Z")

    def test_one_architecture_and_out(self) -> None:
        x64 = self.package("ghostty-1.5.0-tip.7-windows-x86_64.msi")
        out = self.dir / "out"
        code, _, err = run(mf.main, [str(x64), "--tag", mf.TIP_TAG, "--out", str(out)])
        self.assertEqual((code, err), (0, ""))
        feed = json.loads((out / mf.FEED).read_text("utf-8"))
        self.assertEqual(list(feed["packages"]), ["x86_64"])
        self.assertTrue(feed["packages"]["x86_64"]["url"].startswith(mf.RELEASES + "download/tip-windows/"))

    def test_refusals(self) -> None:
        cases = [
            (["ghostty-1.4.1-windows-x86_64.msi", "ghostty-1.4.2-windows-aarch64.msi"], TAG, "versions 1.4.1, 1.4.2"),
            (["ghostty-1.4.1-windows-x86_64.msi", "ghostty-1.4.1-windows-x86_64.msi"], TAG, "two packages for x86_64"),
            (["ghostty-1.4-windows-x86_64.msi"], TAG, "not a semantic version"),
            (["ghostty-1.4.1-windows-riscv64.msi"], TAG, "no such architecture"),
            (["ghostty-1.4.1-linux-x86_64.msi"], TAG, "is not ghostty-<version>-windows-<arch>.msi"),
            (["ghostty-1.4.1-windows-x86_64.zip"], TAG, "is not ghostty-<version>-windows-<arch>.msi"),
            (["ghostty-1.4.1 a-windows-x86_64.msi"], TAG, "not a semantic version"),
            (["ghostty-1.4.1-windows-x86_64.msi"], "a/b", "not a tag Ghostty accepts"),
            (["ghostty-1.4.1-windows-x86_64.msi"], "..", "not a tag Ghostty accepts"),
            # Each channel's packages only on its own release.
            (["ghostty-1.4.1-win.3-windows-x86_64.msi"], mf.TIP_TAG, "1.4.1-win.3 is a stable build, not for tip-windows"),
            (["ghostty-1.5.0-tip.7-windows-x86_64.msi"], "v1.5.0-tip.7", "is a tip build"),
            (["ghostty-1.4.1-win.2-windows-x86_64.msi"], TAG, "tagged v1.4.1-win.2, not v1.4.1-win.3"),
        ]
        for names, tag, says in cases:
            with self.subTest(names=names, tag=tag):
                for n in set(names):
                    self.package(n)
                code, out, err = run(mf.main, [str(self.dir / n) for n in names] + ["--tag", tag])
                self.assertEqual((code, out), (1, ""))
                self.assertIn(says, err)
                self.assertFalse((self.dir / mf.FEED).exists())

    def test_missing_package(self) -> None:
        code, _, err = run(mf.main, [str(self.dir / "ghostty-1.4.1-windows-x86_64.msi"), "--tag", TAG])
        self.assertEqual(code, 1)
        self.assertIn("is not a file", err)


class TestRepository(unittest.TestCase):
    """What the scripts say of Ghostty's updater."""

    def test_feed_is_where_ghostty_looks(self) -> None:
        updater = (REPO / "src/apprt/windows/Updater.zig").read_text("utf-8")
        (releases,) = re.findall(r'const repo_releases = "([^"]+)";', updater)
        (name,) = re.findall(r'const feed_name = "([^"]+)";', updater)
        self.assertEqual(mf.RELEASES, releases)
        self.assertEqual(mf.FEED, name)
        self.assertIn(f'.tip => repo_releases ++ "download/{mf.TIP_TAG}/" ++ feed_name,', updater)
        self.assertIn('.stable => repo_releases ++ "latest/download/" ++ feed_name,', updater)

    def test_accepts_what_ghostty_accepts(self) -> None:
        # `allowed`'s segment characters, as `ghostty_allows` and SEGMENT
        # restate them.
        feed = (REPO / "src/apprt/windows/update_feed.zig").read_text("utf-8")
        self.assertIn("'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '+' => {},", feed)
        self.assertEqual(mf.SEGMENT.pattern, r"[A-Za-z0-9._+-]+")

    def test_installed_copy_is_where_the_package_installs(self) -> None:
        updater = (REPO / "src/apprt/windows/Updater.zig").read_text("utf-8")
        self.assertIn(r'"{s}\\Programs\\Ghostty\\bin\\ghostty.exe"', updater)
        self.assertEqual(mm.EXE, "bin/ghostty.exe")
        self.assertEqual(mm.PRODUCT, "Ghostty")


class TestWinget(Temp):
    @classmethod
    def setUpClass(cls) -> None:
        tmm.tools()
        tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tmp.cleanup)
        cls.built = Path(tmp.name)
        zip_path = tmm.app_zip(cls.built / "zips", version="1.4.1-win.3")
        cls.msi = tmm.build(zip_path, cls.built)
        rows = mm.table(tmm.tools(), cls.msi, "Property")
        (cls.code,) = [r["Value"] for r in rows if r["Property"] == "ProductCode"]

    def test_manifests(self) -> None:
        out = self.dir / "out"
        code, printed, err = run(mw.main, [str(self.msi), "--tag", TAG, "--out", str(out)])
        self.assertEqual((code, err), (0, ""))
        dest = out / "manifests/p/Pyre909/Ghostty/1.4.1-win.3"
        self.assertEqual(printed, f"{dest}\n")
        self.assertEqual(
            sorted(p.name for p in dest.iterdir()),
            ["Pyre909.Ghostty.installer.yaml", "Pyre909.Ghostty.locale.en-US.yaml", "Pyre909.Ghostty.yaml"],
        )
        version = (dest / "Pyre909.Ghostty.yaml").read_text("utf-8")
        self.assertEqual(
            version,
            "# yaml-language-server: $schema=https://aka.ms/winget-manifest.version.1.6.0.schema.json\n\n"
            "PackageIdentifier: 'Pyre909.Ghostty'\n"
            "PackageVersion: '1.4.1-win.3'\n"
            "DefaultLocale: 'en-US'\n"
            "ManifestType: version\n"
            "ManifestVersion: 1.6.0\n",
        )
        installer = (dest / "Pyre909.Ghostty.installer.yaml").read_text("utf-8")
        url = f"{mf.RELEASES}download/{TAG}/{self.msi.name}"
        self.assertIn("InstallerType: 'msi'\nScope: 'user'\nUpgradeBehavior: 'install'\n", installer)
        self.assertIn(
            "Installers:\n"
            "- Architecture: x64\n"
            f"  InstallerUrl: '{url}'\n"
            f"  InstallerSha256: {mz.sha256(self.msi).upper()}\n"
            f"  ProductCode: '{self.code}'\n",
            installer,
        )
        self.assertRegex(self.code, r"\A\{[0-9A-F-]{36}\}\Z")
        self.assertTrue(installer.endswith("ManifestType: installer\nManifestVersion: 1.6.0\n"))
        locale = (dest / "Pyre909.Ghostty.locale.en-US.yaml").read_text("utf-8")
        self.assertIn("Publisher: 'Pyre909'\n", locale)
        self.assertIn(f"ReleaseNotesUrl: '{mf.RELEASES}tag/{TAG}'\n", locale)
        self.assertIn(f"ShortDescription: '{mm.DESCRIPTION}'\n", locale)
        self.assertTrue(locale.endswith("ManifestType: defaultLocale\nManifestVersion: 1.6.0\n"))

    def test_not_for_tip(self) -> None:
        code, out, err = run(mw.main, [str(self.msi), "--tag", mf.TIP_TAG, "--out", str(self.dir)])
        self.assertEqual((code, out), (1, ""))
        self.assertIn("not for winget", err)

    def test_quotes_a_quote(self) -> None:
        self.assertEqual(mw.quote("it's"), "'it''s'")


if __name__ == "__main__":
    unittest.main()
