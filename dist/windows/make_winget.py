"""
Writes the winget manifests for a release of Ghostty's Windows
installers, for a pull request to microsoft/winget-pkgs:

    python3 dist/windows/make_winget.py --tag v1.4.1-win.3 \\
        ghostty-1.4.1-win.3-windows-x86_64.msi ghostty-1.4.1-win.3-windows-aarch64.msi

writes manifests/p/Pyre909/Ghostty/<version>/ beside the first package
(or in --out): the version, installer and default locale manifests of
the multi-file format, schema 1.6.0
(https://learn.microsoft.com/windows/package-manager/package/manifest).

The packages are read as make_feed.py reads them: one per
architecture, of one version, which their names give, each found at
its URL among the release's assets. Each package's ProductCode, which
winget matches against what is installed, is read from the package
with msiinfo (msitools), as make_msi.py reads its packages.

The tip channel's packages are not for winget: a manifest is of one
version, and tip's are replaced in place.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_feed
import make_msi

PUBLISHER = make_msi.MANUFACTURER
IDENTIFIER = f"{PUBLISHER}.{make_msi.PRODUCT}"
MANIFEST_VERSION = "1.6.0"
LOCALE = "en-US"
# winget's names for make_msi.py's architectures.
ARCHES = {"x86_64": "x64", "aarch64": "arm64"}


class Error(Exception):
    pass


def quote(value: str) -> str:
    """A single-quoted YAML scalar, which escapes only its quote."""
    return "'" + value.replace("'", "''") + "'"


def document(kind: str, fields: list[tuple[str, str]], tail: str = "") -> str:
    schema = f"https://aka.ms/winget-manifest.{kind}.{MANIFEST_VERSION}.schema.json"
    lines = [f"# yaml-language-server: $schema={schema}", ""]
    lines += [f"{key}: {quote(value)}" for key, value in fields]
    text = "\n".join(lines) + "\n" + tail
    return text + f"ManifestType: {kind}\nManifestVersion: {MANIFEST_VERSION}\n"


def product_code(tools: dict[str, str], msi: Path) -> str:
    rows = make_msi.table(tools, msi, "Property")
    codes = [r["Value"] for r in rows if r["Property"] == "ProductCode"]
    if len(codes) != 1:
        raise Error(f"{msi.name} has no ProductCode")
    return codes[0]


def manifests(
    packages: list[make_feed.Package], tag: str, codes: dict[str, str]
) -> dict[str, str]:
    """Each manifest's text by its file name."""
    if tag == make_feed.TIP_TAG:
        raise Error("tip's packages are replaced in place, so are not for winget")
    make_feed.check_release(packages[0].version, tag)
    version = packages[0].version
    head = [("PackageIdentifier", IDENTIFIER), ("PackageVersion", version)]
    installers = "Installers:\n"
    for p in packages:
        installers += (
            f"- Architecture: {ARCHES[p.arch]}\n"
            f"  InstallerUrl: {quote(f'{make_feed.RELEASES}download/{tag}/{p.path.name}')}\n"
            f"  InstallerSha256: {p.sha256.upper()}\n"
            f"  ProductCode: {quote(codes[p.arch])}\n"
        )
    return {
        f"{IDENTIFIER}.yaml": document("version", head + [("DefaultLocale", LOCALE)]),
        f"{IDENTIFIER}.installer.yaml": document(
            "installer",
            # The package installs for the user alone, without elevation,
            # and an upgrade replaces the installed version in place
            # (make_msi.py's MajorUpgrade).
            head
            + [
                ("InstallerType", "msi"),
                ("Scope", "user"),
                ("UpgradeBehavior", "install"),
            ],
            installers,
        ),
        f"{IDENTIFIER}.locale.{LOCALE}.yaml": document(
            "defaultLocale",
            head
            + [
                ("PackageLocale", LOCALE),
                ("Publisher", PUBLISHER),
                ("PublisherUrl", make_msi.HOMEPAGE.rsplit("/", 1)[0]),
                ("PackageName", make_msi.PRODUCT),
                ("PackageUrl", make_msi.HOMEPAGE),
                ("License", "MIT"),
                ("LicenseUrl", make_msi.HOMEPAGE + "/blob/main/LICENSE"),
                ("ShortDescription", make_msi.DESCRIPTION),
                ("ReleaseNotesUrl", f"{make_feed.RELEASES}tag/{tag}"),
            ],
        ),
    }


def make(args: argparse.Namespace) -> Path:
    found = shutil.which("msiinfo")
    if found is None:
        raise Error("msiinfo is not on PATH; it is part of msitools")
    tools = {"msiinfo": found}
    packages = make_feed.read_packages([p.resolve() for p in args.packages])
    codes = {p.arch: product_code(tools, p.path) for p in packages}
    texts = manifests(packages, args.tag, codes)
    out = (args.out or packages[0].path.parent).resolve()
    dest = out / "manifests" / "p" / PUBLISHER / make_msi.PRODUCT / packages[0].version
    dest.mkdir(parents=True, exist_ok=True)
    for name, text in texts.items():
        (dest / name).write_text(text, "utf-8")
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Write the winget manifests for a release."
    )
    parser.add_argument("packages", type=Path, nargs="+", help="make_msi.py's packages")
    parser.add_argument("--tag", required=True, help="the release's tag")
    parser.add_argument(
        "--out", type=Path, help="where to write (beside the first package)"
    )
    args = parser.parse_args(argv)
    try:
        dest = make(args)
    except (Error, make_feed.Error, make_msi.Error) as e:
        print(f"make_winget: {e}", file=sys.stderr)
        return 1
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
