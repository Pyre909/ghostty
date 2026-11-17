"""
Tests for make_feed.py and make_winget.py:

    python3 -I dist/windows/test_make_feed.py

The winget tests build a package for real, as test_make_msi.py does, so
they need msitools and fail without it. Whether Ghostty accepts the feed
is tested against update_feed.zig's own rules (`allowed`), restated
here and checked against its source, not by running it.
"""

from __future__ import annotations

import base64
import contextlib
import io
import json
import re
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_feed as mf
import make_msi as mm
import make_winget as mw
import make_zip as mz
import test_make_msi as tmm

REPO = Path(__file__).resolve().parents[2]
TAG = "v1.4.1-win.3"
# The feed both make_feed.py and Ghostty's parser are tested against
# (update_feed.zig embeds it), and its signature.
FIXTURE = REPO / "src/apprt/windows/testdata"
# RFC 8032's first Ed25519 test key (section 7.1, TEST 1): it signs only
# the fixture, and its public half is published with the RFC.
TEST_SEED = bytes.fromhex(
    "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
)
TEST_PUBLIC = "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"


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
        code, out, err = run(mf.main, [str(arm), str(x64), "--tag", TAG, "--unsigned"])
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
        code, _, err = run(
            mf.main, [str(x64), "--tag", mf.TIP_TAG, "--out", str(out), "--unsigned"]
        )
        self.assertEqual((code, err), (0, ""))
        feed = json.loads((out / mf.FEED).read_text("utf-8"))
        self.assertEqual(list(feed["packages"]), ["x86_64"])
        self.assertTrue(
            feed["packages"]["x86_64"]["url"].startswith(
                mf.RELEASES + "download/tip-windows/"
            )
        )

    def test_refusals(self) -> None:
        cases = [
            (
                [
                    "ghostty-1.4.1-windows-x86_64.msi",
                    "ghostty-1.4.2-windows-aarch64.msi",
                ],
                TAG,
                "versions 1.4.1, 1.4.2",
            ),
            (
                [
                    "ghostty-1.4.1-windows-x86_64.msi",
                    "ghostty-1.4.1-windows-x86_64.msi",
                ],
                TAG,
                "two packages for x86_64",
            ),
            (["ghostty-1.4-windows-x86_64.msi"], TAG, "not a semantic version"),
            (["ghostty-1.4.1-windows-riscv64.msi"], TAG, "no such architecture"),
            (
                ["ghostty-1.4.1-linux-x86_64.msi"],
                TAG,
                "is not ghostty-<version>-windows-<arch>.msi",
            ),
            (
                ["ghostty-1.4.1-windows-x86_64.zip"],
                TAG,
                "is not ghostty-<version>-windows-<arch>.msi",
            ),
            (["ghostty-1.4.1 a-windows-x86_64.msi"], TAG, "not a semantic version"),
            # Numbers past a usize, which Ghostty cannot read.
            (
                ["ghostty-18446744073709551616.0.0-windows-x86_64.msi"],
                TAG,
                "has a number past 18446744073709551615",
            ),
            (
                ["ghostty-1.4.1-win.18446744073709551616-windows-x86_64.msi"],
                TAG,
                "has a number past",
            ),
            (["ghostty-1.4.1-windows-x86_64.msi"], "a/b", "not a tag Ghostty accepts"),
            (["ghostty-1.4.1-windows-x86_64.msi"], "..", "not a tag Ghostty accepts"),
            # Each channel's packages only on its own release.
            (
                ["ghostty-1.4.1-win.3-windows-x86_64.msi"],
                mf.TIP_TAG,
                "1.4.1-win.3 is a stable build, not for tip-windows",
            ),
            (
                ["ghostty-1.5.0-tip.7-windows-x86_64.msi"],
                "v1.5.0-tip.7",
                "is a tip build",
            ),
            (
                ["ghostty-1.4.1-win.2-windows-x86_64.msi"],
                TAG,
                "tagged v1.4.1-win.2, not v1.4.1-win.3",
            ),
            (
                ["ghostty-1.4.1-win.3-windows-x86_64.msi"],
                mf.STABLE_TAG,
                "holds only the feed",
            ),
        ]
        for names, tag, says in cases:
            with self.subTest(names=names, tag=tag):
                for n in set(names):
                    self.package(n)
                code, out, err = run(
                    mf.main,
                    [str(self.dir / n) for n in names] + ["--tag", tag, "--unsigned"],
                )
                self.assertEqual((code, out), (1, ""))
                self.assertIn(says, err)
                self.assertFalse((self.dir / mf.FEED).exists())

    def test_largest_numbers_ghostty_reads(self) -> None:
        name = "ghostty-1.4.1-win.18446744073709551615-windows-x86_64.msi"
        (p,) = mf.read_packages([self.package(name)])
        self.assertEqual(p.version, "1.4.1-win.18446744073709551615")

    def test_missing_package(self) -> None:
        code, _, err = run(
            mf.main,
            [
                str(self.dir / "ghostty-1.4.1-windows-x86_64.msi"),
                "--tag",
                TAG,
                "--unsigned",
            ],
        )
        self.assertEqual(code, 1)
        self.assertIn("is not a file", err)


def test_key(directory: Path) -> Path:
    """The RFC 8032 test key, as the PEM file OpenSSL reads."""
    der = bytes.fromhex("302e020100300506032b657004220420") + TEST_SEED
    pem = (
        "-----BEGIN PRIVATE KEY-----\n"
        + base64.b64encode(der).decode()
        + "\n-----END PRIVATE KEY-----\n"
    )
    path = directory / "key.pem"
    path.write_text(pem, "ascii")
    return path


class TestSigned(Temp):
    def packages(self) -> list[str]:
        return [
            str(self.package("ghostty-1.4.1-win.3-windows-aarch64.msi", b"arm")),
            str(self.package("ghostty-1.4.1-win.3-windows-x86_64.msi", b"x64")),
        ]

    def test_writes_the_fixture_ghostty_reads(self) -> None:
        # Byte for byte, the feed and signature update_feed.zig's test
        # verifies and parses: a change to the format on either side
        # fails one of the two.
        key = test_key(self.dir)
        code, out, err = run(
            mf.main, self.packages() + ["--tag", TAG, "--key", str(key)]
        )
        self.assertEqual((code, err), (0, ""))
        for name in (mf.FEED, mf.SIGNATURE):
            with self.subTest(name=name):
                self.assertEqual(
                    (self.dir / name).read_bytes(), (FIXTURE / name).read_bytes()
                )

    def test_prints_the_public_key(self) -> None:
        code, out, err = run(mf.main, ["--public-key", str(test_key(self.dir))])
        self.assertEqual((code, out, err), (0, TEST_PUBLIC + "\n", ""))

    def test_signs_or_says_it_does_not(self) -> None:
        key = test_key(self.dir)
        for extra, says in [
            ([], "give --key"),
            (["--key", str(key), "--unsigned"], "give --key"),
        ]:
            with self.subTest(extra=extra):
                code, out, err = run(mf.main, self.packages() + ["--tag", TAG, *extra])
                self.assertEqual((code, out), (1, ""))
                self.assertIn(says, err)
        # An unsigned feed leaves no signature of an earlier one beside it.
        self.assertEqual(
            run(mf.main, self.packages() + ["--tag", TAG, "--key", str(key)])[0], 0
        )
        self.assertEqual(
            run(mf.main, self.packages() + ["--tag", TAG, "--unsigned"])[0], 0
        )
        self.assertFalse((self.dir / mf.SIGNATURE).exists())

    def test_refuses_another_kind_of_key(self) -> None:
        other = self.dir / "ed448.pem"
        mf.openssl("openssl", ["genpkey", "-algorithm", "ed448", "-out", str(other)])
        code, out, err = run(
            mf.main, self.packages() + ["--tag", TAG, "--key", str(other)]
        )
        self.assertEqual((code, out), (1, ""))
        self.assertIn("is not an Ed25519 key", err)
        self.assertFalse((self.dir / mf.SIGNATURE).exists())


class TestRepository(unittest.TestCase):
    """What the scripts say of Ghostty's updater."""

    def test_feed_is_where_ghostty_looks(self) -> None:
        updater = (REPO / "src/apprt/windows/Updater.zig").read_text("utf-8")
        (releases,) = re.findall(r'const repo_releases = "([^"]+)";', updater)
        (name,) = re.findall(r'const feed_name = "([^"]+)";', updater)
        self.assertEqual(mf.RELEASES, releases)
        self.assertEqual(mf.FEED, name)
        self.assertIn(
            f'.tip => repo_releases ++ "download/{mf.TIP_TAG}/" ++ feed_name,', updater
        )
        self.assertIn(
            f'.stable => repo_releases ++ "download/{mf.STABLE_TAG}/" ++ feed_name,',
            updater,
        )

    def test_accepts_what_ghostty_accepts(self) -> None:
        # `allowed`'s segment characters, as `ghostty_allows` and SEGMENT
        # restate them.
        feed = (REPO / "src/apprt/windows/update_feed.zig").read_text("utf-8")
        self.assertIn(
            "'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '+' => {},", feed
        )
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
        arm_zip = tmm.app_zip(
            cls.built / "arm-zips", version="1.4.1-win.3", arch="aarch64"
        )
        cls.arm_msi = tmm.build(arm_zip, cls.built)
        cls.code = cls.product_code(cls.msi)
        cls.arm_code = cls.product_code(cls.arm_msi)

    @staticmethod
    def product_code(msi: Path) -> str:
        rows = mm.table(tmm.tools(), msi, "Property")
        (code,) = [r["Value"] for r in rows if r["Property"] == "ProductCode"]
        return code

    def test_manifests(self) -> None:
        out = self.dir / "out"
        code, printed, err = run(
            mw.main, [str(self.msi), "--tag", TAG, "--out", str(out)]
        )
        self.assertEqual((code, err), (0, ""))
        dest = out / "manifests/p/Pyre909/Ghostty/1.4.1-win.3"
        self.assertEqual(printed, f"{dest}\n")
        self.assertEqual(
            sorted(p.name for p in dest.iterdir()),
            [
                "Pyre909.Ghostty.installer.yaml",
                "Pyre909.Ghostty.locale.en-US.yaml",
                "Pyre909.Ghostty.yaml",
            ],
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
        self.assertIn(
            "InstallerType: 'msi'\nScope: 'user'\nUpgradeBehavior: 'install'\n",
            installer,
        )
        self.assertIn(
            "Installers:\n"
            "- Architecture: x64\n"
            f"  InstallerUrl: '{url}'\n"
            f"  InstallerSha256: {mz.sha256(self.msi).upper()}\n"
            f"  ProductCode: '{self.code}'\n"
            "  AppsAndFeaturesEntries:\n"
            "  - DisplayVersion: '1.4.1.3'\n",
            installer,
        )
        self.assertRegex(self.code, r"\A\{[0-9A-F-]{36}\}\Z")
        self.assertTrue(
            installer.endswith("ManifestType: installer\nManifestVersion: 1.6.0\n")
        )
        locale = (dest / "Pyre909.Ghostty.locale.en-US.yaml").read_text("utf-8")
        self.assertIn("Publisher: 'Pyre909'\n", locale)
        self.assertIn(f"ReleaseNotesUrl: '{mf.RELEASES}tag/{TAG}'\n", locale)
        self.assertIn(f"ShortDescription: '{mm.DESCRIPTION}'\n", locale)
        self.assertTrue(
            locale.endswith("ManifestType: defaultLocale\nManifestVersion: 1.6.0\n")
        )

    def test_each_architecture_its_own_installer(self) -> None:
        # Given aarch64 first, written in make_msi.PLATFORMS' order, each
        # with its own package's URL, hash and ProductCode, which differ.
        out = self.dir / "out"
        argv = [str(self.arm_msi), str(self.msi), "--tag", TAG, "--out", str(out)]
        code, _, err = run(mw.main, argv)
        self.assertEqual((code, err), (0, ""))
        self.assertNotEqual(self.code, self.arm_code)
        installer = (
            out
            / "manifests/p/Pyre909/Ghostty/1.4.1-win.3/Pyre909.Ghostty.installer.yaml"
        ).read_text("utf-8")
        entries = ""
        for arch, msi, product in [
            ("x64", self.msi, self.code),
            ("arm64", self.arm_msi, self.arm_code),
        ]:
            entries += (
                f"- Architecture: {arch}\n"
                f"  InstallerUrl: '{mf.RELEASES}download/{TAG}/{msi.name}'\n"
                f"  InstallerSha256: {mz.sha256(msi).upper()}\n"
                f"  ProductCode: '{product}'\n"
                "  AppsAndFeaturesEntries:\n"
                "  - DisplayVersion: '1.4.1.3'\n"
            )
        self.assertIn(
            "Installers:\n" + entries + "ManifestType: installer\n", installer
        )

    def test_partition_is_the_identifiers_letter(self) -> None:
        out = self.dir / "out"
        with (
            mock.patch.object(mw, "PUBLISHER", "Zed"),
            mock.patch.object(mw, "IDENTIFIER", "Zed.Ghostty"),
        ):
            code, printed, err = run(
                mw.main, [str(self.msi), "--tag", TAG, "--out", str(out)]
            )
        self.assertEqual((code, err), (0, ""))
        self.assertEqual(printed, f"{out / 'manifests/z/Zed/Ghostty/1.4.1-win.3'}\n")

    def test_bad_tag(self) -> None:
        code, out, err = run(
            mw.main, [str(self.msi), "--tag", "a/b", "--out", str(self.dir)]
        )
        self.assertEqual((code, out), (1, ""))
        self.assertIn("not a tag Ghostty accepts", err)

    def test_not_for_tip(self) -> None:
        code, out, err = run(
            mw.main, [str(self.msi), "--tag", mf.TIP_TAG, "--out", str(self.dir)]
        )
        self.assertEqual((code, out), (1, ""))
        self.assertIn("not for winget", err)

    def test_quotes_a_quote(self) -> None:
        self.assertEqual(mw.quote("it's"), "'it''s'")


if __name__ == "__main__":
    unittest.main()
