"""
Writes the update feed for a release of Ghostty's Windows installers,
which a running Ghostty fetches to learn of an update
(src/apprt/windows/update_feed.zig):

    python3 dist/windows/make_feed.py --tag v1.4.1-win.3 \\
        ghostty-1.4.1-win.3-windows-x86_64.msi ghostty-1.4.1-win.3-windows-aarch64.msi

writes ghostty-windows-update.json beside the first package (or in
--out), to be published as an asset of the release `--tag` names, with
the packages. The stable channel's feed is the latest release's
(releases/latest/download/...), the tip channel's the release tagged
tip-windows, so a tip build is published under that tag, replacing the
assets it had.

The packages are those make_msi.py made, one per architecture, of one
version, which their names give. The feed names each by its URL among
the release's assets, with its SHA-256, which Ghostty checks before it
installs one; and the release's page, for its notes.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_msi
import make_zip

# What Ghostty's build names as its releases (`Updater.Source`), and the
# feed's name under them.
RELEASES = make_msi.HOMEPAGE + "/releases/"
FEED = "ghostty-windows-update.json"
TIP_TAG = "tip-windows"

PACKAGE = re.compile(r"ghostty-(?P<version>.+)-windows-(?P<arch>[a-z0-9_]+)\.msi", re.ASCII)

# semver.org's own expression, which `std.SemanticVersion.parse` follows.
SEMVER = re.compile(
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?",
    re.ASCII,
)

# A URL segment Ghostty accepts (`update_feed.allowed`).
SEGMENT = re.compile(r"[A-Za-z0-9._+-]+", re.ASCII)


class Error(Exception):
    pass


@dataclass(frozen=True)
class Package:
    path: Path
    version: str
    arch: str
    sha256: str


def read_packages(paths: list[Path]) -> list[Package]:
    """The packages at `paths`, one per architecture, of one version,
    in the order of `make_msi.PLATFORMS`."""
    if not paths:
        raise Error("no package given")
    packages: dict[str, Package] = {}
    for path in paths:
        m = PACKAGE.fullmatch(path.name)
        if m is None:
            raise Error(f"{path.name} is not ghostty-<version>-windows-<arch>.msi")
        version, arch = m["version"], m["arch"]
        if arch not in make_msi.PLATFORMS:
            raise Error(f"{path.name}: no such architecture {arch!r}")
        if SEMVER.fullmatch(version) is None:
            raise Error(f"{path.name}: {version!r} is not a semantic version")
        if SEGMENT.fullmatch(path.name) is None or path.name in (".", ".."):
            raise Error(f"{path.name} is not a plain name")
        if not path.is_file():
            raise Error(f"{path} is not a file")
        if arch in packages:
            raise Error(f"two packages for {arch}")
        packages[arch] = Package(path, version, arch, make_zip.sha256(path))
    versions = {p.version for p in packages.values()}
    if len(versions) > 1:
        raise Error("the packages are of versions " + ", ".join(sorted(versions)))
    return [packages[a] for a in make_msi.PLATFORMS if a in packages]


def check_tag(tag: str) -> None:
    if SEGMENT.fullmatch(tag) is None or tag in (".", ".."):
        raise Error(f"{tag!r} is not a tag Ghostty accepts in a URL")


def feed(packages: list[Package], tag: str) -> dict:
    check_tag(tag)
    return {
        "version": packages[0].version,
        "notes": f"{RELEASES}tag/{tag}",
        "packages": {
            p.arch: {
                "url": f"{RELEASES}download/{tag}/{p.path.name}",
                "sha256": p.sha256,
            }
            for p in packages
        },
    }


def make(args: argparse.Namespace) -> Path:
    packages = read_packages([p.resolve() for p in args.packages])
    out = (args.out or packages[0].path.parent).resolve()
    out.mkdir(parents=True, exist_ok=True)
    dest = out / FEED
    text = json.dumps(feed(packages, args.tag), indent=2) + "\n"
    dest.write_text(text, "utf-8")
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write the update feed for a release.")
    parser.add_argument("packages", type=Path, nargs="+", help="make_msi.py's packages")
    parser.add_argument("--tag", required=True, help=f"the release's tag ({TIP_TAG} for tip)")
    parser.add_argument("--out", type=Path, help="where to write (beside the first package)")
    args = parser.parse_args(argv)
    try:
        dest = make(args)
    except Error as e:
        print(f"make_feed: {e}", file=sys.stderr)
        return 1
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
