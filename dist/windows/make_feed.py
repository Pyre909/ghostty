"""
Writes the update feed for a release of Ghostty's Windows installers,
which a running Ghostty fetches to learn of an update
(src/apprt/windows/update_feed.zig):

    python3 dist/windows/make_feed.py --tag v1.4.1-win.3 \\
        ghostty-1.4.1-win.3-windows-x86_64.msi ghostty-1.4.1-win.3-windows-aarch64.msi

writes ghostty-windows-update.json beside the first package (or in
--out). Each channel's Ghostty reads the feed at a release of its own:
stable's at the release tagged stable-windows, tip's at tip-windows. A
stable release publishes its packages and the feed on its own tag
(--tag), then replaces the feed on stable-windows with the same file;
stable-windows holds nothing else, and is never marked the latest
release (gh release create --latest=false), as the latest release is
whatever was published last. A tip build is published under
tip-windows, replacing the assets it had.

The packages are those make_msi.py made, one per architecture, of one
version, which their names give. The feed names each by its URL among
the release's assets, with its SHA-256, which Ghostty checks before it
installs one; and the release's page, for its notes.

--key signs the feed: ghostty-windows-update.json.sig, beside it and
published with it, is an Ed25519 signature over its exact bytes. A
Ghostty built with the key's public half (-Dupdate-public-key, which
make_zip.py passes on) installs an update only from a feed that
signature verifies; one built without it only offers the release page,
and --unsigned writes the feed for such builds. The key is made once,
with OpenSSL 3 or later, and kept apart from the token that uploads
releases (as upstream keeps its Sparkle key in a CI secret):

    openssl genpkey -algorithm ed25519 -out ghostty-update-key.pem
    python3 dist/windows/make_feed.py --public-key ghostty-update-key.pem

the second printing the hex that -Dupdate-public-key takes. That takes
two keys too, comma-separated, the second the next key: to change keys,
release builds that trust both, then sign with the new one, and drop the
old from the builds after.

A signed feed expires (--valid-days, 90 by default): a Ghostty with the
key refuses it after that, so a feed replayed or frozen at an old
release stops being believed. Before it expires, sign it again with a
new date, changing nothing else:

    python3 dist/windows/make_feed.py --renew ghostty-windows-update.json \\
        --key ghostty-update-key.pem

and replace both files on the release (and on stable-windows).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
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
SIGNATURE = FEED + ".sig"
TIP_TAG = "tip-windows"
STABLE_TAG = "stable-windows"

# The largest number `std.SemanticVersion.parse` reads: a usize, which
# is 64 bits on each architecture a package is for.
MAX_NUMBER = 2**64 - 1

# How long a feed is believed, by default; and the latest `expires` an
# i64 holds, as `update_feed.Feed` reads it.
VALID_DAYS = 90
DAY = 24 * 60 * 60
MAX_EXPIRES = 2**63 - 1

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
        # Named as make_msi.py names a package: its app's folder, .msi.
        stem = path.name.removesuffix(".msi")
        m = make_msi.FOLDER.fullmatch(stem) if stem != path.name else None
        if m is None:
            raise Error(f"{path.name} is not ghostty-<version>-windows-<arch>.msi")
        version, arch = m["version"], m["arch"]
        if arch not in make_msi.PLATFORMS:
            raise Error(f"{path.name}: no such architecture {arch!r}")
        check_version(version, path.name)
        if not path.is_file():
            raise Error(f"{path} is not a file")
        if arch in packages:
            raise Error(f"two packages for {arch}")
        packages[arch] = Package(path, version, arch, make_zip.sha256(path))
    versions = {p.version for p in packages.values()}
    if len(versions) > 1:
        raise Error("the packages are of versions " + ", ".join(sorted(versions)))
    return [packages[a] for a in make_msi.PLATFORMS if a in packages]


def check_version(version: str, name: str) -> None:
    """Refuse a version Ghostty would not read: one not semantic, or with
    a number past what `std.SemanticVersion.parse` reads. (A name of a
    semantic version holds only characters a URL segment of the feed may,
    SEGMENT.)"""
    m = make_zip.SEMVER.fullmatch(version)
    if m is None:
        raise Error(f"{name}: {version!r} is not a semantic version")
    numbers = [m[1], m[2], m[3], *(m[4] or "").split(".")]
    if any(n.isdigit() and int(n) > MAX_NUMBER for n in numbers):
        raise Error(f"{name}: {version!r} has a number past {MAX_NUMBER}")


def check_tag(tag: str) -> None:
    if SEGMENT.fullmatch(tag) is None or tag in (".", ".."):
        raise Error(f"{tag!r} is not a tag Ghostty accepts in a URL")


def check_release(version: str, tag: str) -> None:
    """Refuse packages of `version` for the release `tag`: tip's tag
    takes only a tip build, any other only the stable build it names
    (v<version>), as a feed's packages read the feed of their own channel
    (make_zip.channel)."""
    check_tag(tag)
    if tag == STABLE_TAG:
        raise Error(f"{tag} holds only the feed: give the release's own tag")
    built = make_zip.channel(version)
    if tag == TIP_TAG:
        if built != "tip":
            raise Error(f"{version} is a {built} build, not for {tag}")
    elif built != "stable":
        raise Error(f"{version} is a {built} build, not for {tag}")
    elif tag != f"v{version}":
        raise Error(f"a release of {version} is tagged v{version}, not {tag}")


def package_url(tag: str, name: str) -> str:
    """The URL of the release `tag`'s asset `name`."""
    return f"{RELEASES}download/{tag}/{name}"


def notes_url(tag: str) -> str:
    """The URL of the release `tag`'s page."""
    return f"{RELEASES}tag/{tag}"


def expiry(args: argparse.Namespace) -> int:
    """When the feed expires, in Unix seconds: --expires, or --valid-days
    from now."""
    if args.expires is not None and args.valid_days is not None:
        raise Error("give --expires or --valid-days, not both")
    if args.expires is not None:
        expires = args.expires
    else:
        days = VALID_DAYS if args.valid_days is None else args.valid_days
        if days <= 0:
            raise Error(f"--valid-days {days} is not a number of days to come")
        expires = int(time.time()) + days * DAY
    if not 0 < expires <= MAX_EXPIRES:
        raise Error(f"{expires} is not a time Ghostty reads")
    if expires <= time.time():
        raise Error(f"{expires} has passed: Ghostty would refuse the feed")
    return expires


def feed(packages: list[Package], tag: str, expires: int) -> dict:
    check_release(packages[0].version, tag)
    return {
        "version": packages[0].version,
        "expires": expires,
        "notes": notes_url(tag),
        "packages": {
            p.arch: {
                "url": package_url(tag, p.path.name),
                "sha256": p.sha256,
            }
            for p in packages
        },
    }


# An Ed25519 public key's DER (SubjectPublicKeyInfo, RFC 8410) is this,
# then the key's 32 bytes.
ED25519_SPKI = bytes.fromhex("302a300506032b6570032100")


def openssl(tool: str, args: list[str]) -> bytes:
    try:
        run = subprocess.run([tool, *args], capture_output=True, check=False)
    except OSError as e:
        raise Error(f"{tool} not run: {e}") from e
    if run.returncode != 0:
        raise Error(
            f"{tool} {args[0]} failed: {run.stderr.decode(errors='replace').strip()}"
        )
    return run.stdout


def public_key(tool: str, key: Path) -> str:
    """The Ed25519 key at `key`'s public half, as -Dupdate-public-key
    takes it."""
    der = openssl(tool, ["pkey", "-in", str(key), "-pubout", "-outform", "DER"])
    if len(der) != len(ED25519_SPKI) + 32 or not der.startswith(ED25519_SPKI):
        raise Error(f"{key} is not an Ed25519 key")
    return der[len(ED25519_SPKI) :].hex()


def sign(tool: str, key: Path, feed_path: Path) -> Path:
    """Sign the file at `feed_path` with `key`: the signature's path."""
    public_key(tool, key)
    dest = feed_path.with_name(SIGNATURE)
    openssl(
        tool,
        [
            "pkeyutl",
            "-sign",
            "-rawin",
            "-inkey",
            str(key),
            "-in",
            str(feed_path),
            "-out",
            str(dest),
        ],
    )
    if dest.stat().st_size != 64:
        raise Error(f"{dest} is not an Ed25519 signature")
    return dest


def write(dest: Path, content: dict, args: argparse.Namespace) -> None:
    """Write the feed `content` to `dest`, and sign it unless --unsigned.
    Both are made in a stage beside `dest` and moved into place only once
    signed, as make_zip.py stages its zips: a key or OpenSSL that fails
    leaves the feed and signature that were there."""
    text = json.dumps(content, indent=2) + "\n"
    with tempfile.TemporaryDirectory(dir=dest.parent, prefix=".stage-") as stage:
        staged = Path(stage) / dest.name
        staged.write_text(text, "utf-8")
        if args.key is not None:
            os.replace(sign(args.openssl, args.key, staged), dest.with_name(SIGNATURE))
        else:
            dest.with_name(SIGNATURE).unlink(missing_ok=True)
        os.replace(staged, dest)


def renew(args: argparse.Namespace) -> Path:
    """The feed at --renew, its `expires` moved and signed again: nothing
    else of it changes."""
    if args.key is None:
        raise Error("--renew signs the feed again: give its --key")
    if args.packages or args.tag is not None or args.unsigned:
        raise Error("--renew takes only the feed, its --key and its expiry")
    dest = args.renew.resolve()
    try:
        content = json.loads(dest.read_text("utf-8"))
    except (OSError, ValueError) as e:
        raise Error(f"{dest} is not a feed: {e}") from e
    if not isinstance(content, dict) or not {"version", "packages"} <= content.keys():
        raise Error(f"{dest} is not a feed")
    expires = expiry(args)
    # In the place make writes it, for a feed of an older make_feed.py too.
    content = {
        "version": content["version"],
        "expires": expires,
        **{k: v for k, v in content.items() if k not in ("version", "expires")},
    }
    write(dest, content, args)
    return dest


def make(args: argparse.Namespace) -> Path:
    if args.renew is not None:
        return renew(args)
    if args.tag is None:
        raise Error("give the release's --tag")
    if (args.key is None) == (not args.unsigned):
        raise Error(
            "give --key to sign the feed, or --unsigned for builds with no update key"
        )
    packages = read_packages([p.resolve() for p in args.packages])
    out = (args.out or packages[0].path.parent).resolve()
    out.mkdir(parents=True, exist_ok=True)
    dest = out / FEED
    write(dest, feed(packages, args.tag, expiry(args)), args)
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Write the update feed for a release.")
    parser.add_argument("packages", type=Path, nargs="*", help="make_msi.py's packages")
    parser.add_argument("--tag", help=f"the release's tag ({TIP_TAG} for tip)")
    parser.add_argument(
        "--out", type=Path, help="where to write (beside the first package)"
    )
    parser.add_argument(
        "--key", type=Path, help="the Ed25519 private key (PEM) to sign the feed with"
    )
    parser.add_argument("--unsigned", action="store_true", help="write no signature")
    parser.add_argument(
        "--valid-days",
        type=int,
        help=f"days until the feed expires ({VALID_DAYS})",
    )
    parser.add_argument(
        "--expires", type=int, help="when the feed expires, in Unix seconds"
    )
    parser.add_argument(
        "--renew",
        type=Path,
        metavar="FEED",
        help="sign FEED again with a new expiry, changing nothing else",
    )
    parser.add_argument(
        "--public-key",
        type=Path,
        metavar="KEY",
        help="print KEY's public half and stop",
    )
    parser.add_argument(
        "--openssl", default="openssl", help="OpenSSL 3 or later (openssl)"
    )
    args = parser.parse_args(argv)
    try:
        if args.public_key is not None:
            print(public_key(args.openssl, args.public_key))
            return 0
        dest = make(args)
    except Error as e:
        print(f"make_feed: {e}", file=sys.stderr)
        return 1
    print(dest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
