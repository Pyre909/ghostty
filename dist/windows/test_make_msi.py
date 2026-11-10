"""
Tests for make_msi.py:

    python3 -I dist/windows/test_make_msi.py

The packages are built for real, from small app zips, so the tests need
msitools as make_msi.py does, and fail without it rather than pass having
built nothing. What an installed package does on Windows is not tested
here.
"""

from __future__ import annotations

import contextlib
import io
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import warnings
import zipfile
from pathlib import Path
from unittest import mock
from xml.etree import ElementTree

# Import make_msi from beside this file, without leaving a __pycache__.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_msi as mm
import make_zip as mz

REPO = Path(__file__).resolve().parents[2]
WHEN = (2026, 1, 2, 3, 4, 6)
WIX = "{" + mm.WIX + "}"


def pe(machine: int) -> bytes:
    head = bytearray(64)
    head[:2] = b"MZ"
    head[0x3C:0x40] = (64).to_bytes(4, "little")
    return bytes(head) + b"PE\0\0" + machine.to_bytes(2, "little") + bytes(18)


def app_files(arch: str = "x86_64") -> dict[str, bytes]:
    """The shapes of the real app: the files the package points at, a
    name with a space, a name longer than 8.3, and folders that hold only
    folders (share, share/ghostty, share/terminfo and those above the
    icon)."""
    return {
        "bin/ghostty.exe": pe(mz.ARCHES[arch]),
        "bin/ghostty.com": pe(mz.ARCHES[arch]),
        "README.txt": b"readme\n",
        "LICENSE.txt": b"license\n",
        "THIRD-PARTY-NOTICES.txt": b"notices\n",
        "share/ghostty/themes/3024 Day": b"background = #f7f7f7\n",
        mm.TOAST_ICON: b"\x89PNG\r\n\x1a\n",
        "share/terminfo/x/xterm-ghostty": b"\x1a\x01",
    }


# The folders of `app_files`, as paths under the top one (".").
FOLDERS = [
    ".",
    "bin",
    "share",
    r"share\ghostty",
    r"share\ghostty\themes",
    r"share\icons",
    r"share\icons\hicolor",
    r"share\icons\hicolor\256x256",
    r"share\icons\hicolor\256x256\apps",
    r"share\terminfo",
    r"share\terminfo\x",
]


def app_zip(
    where: Path,
    files: dict[str, bytes] | None = None,
    version: str = "1.4.1",
    arch: str = "x86_64",
    top: str | None = None,
    when: tuple[int, int, int, int, int, int] = WHEN,
) -> Path:
    files = app_files(arch) if files is None else files
    top = f"ghostty-{version}-windows-{arch}" if top is None else top
    where.mkdir(parents=True, exist_ok=True)
    dest = where / f"{top}.zip"
    mz.write_zip(dest, {f"{top}/{k}": v for k, v in files.items()}, when)
    return dest


def tools() -> dict[str, str]:
    found = {t: shutil.which(t) for t in ("wixl", "msibuild", "msiinfo")}
    missing = sorted(t for t, path in found.items() if path is None)
    if missing:
        raise AssertionError(f"msitools is not installed: no {', '.join(missing)}")
    return {t: str(path) for t, path in found.items()}


def build(zip_path: Path, out: Path) -> Path:
    """The package make_msi.py makes of a zip, in `out`."""
    printed = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(printed), contextlib.redirect_stderr(err):
        code = mm.main([str(zip_path), "--out", str(out)])
    if code != 0:
        raise AssertionError(f"make_msi failed:\n{err.getvalue()}")
    dest = out / (zip_path.stem + ".msi")
    assert printed.getvalue() == f"{mz.sha256(dest)}  {dest.name}\n", printed.getvalue()
    return dest


def fails(zip_path: Path, out: Path) -> str:
    """What make_msi.py says of a zip it refuses."""
    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        code = mm.main([str(zip_path), "--out", str(out)])
    assert code == 1, code
    return err.getvalue()


class Temp(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)

    def read(self, files: dict[str, bytes], **kw: object) -> mm.App:
        with zipfile.ZipFile(app_zip(self.tmp, files, **kw)) as zf:  # type: ignore[arg-type]
            return mm.read_app(zf)

    def refused(self, files: dict[str, bytes], **kw: object) -> str:
        with self.assertRaises(mm.Error) as e:
            self.read(files, **kw)
        return str(e.exception)


class TestReadApp(Temp):
    def test_reads_an_app(self) -> None:
        app = self.read(app_files("aarch64"), version="1.4.1-dev+abc", arch="aarch64")
        self.assertEqual(app.name, "ghostty-1.4.1-dev+abc-windows-aarch64")
        self.assertEqual((app.version, app.arch), ("1.4.1-dev+abc", "aarch64"))
        self.assertEqual(sorted(app.files), sorted(app_files()))
        # Parents first, and the folders that hold no file of their own.
        self.assertEqual(app.dirs(), ["", *[f.replace("\\", "/") for f in FOLDERS[1:]]])

    def test_names_as_make_zip_writes_them(self) -> None:
        # make_zip.make names the folder ghostty-<version>-windows-<arch>
        # for these architectures and installs these files in bin.
        self.assertEqual(sorted(mm.PLATFORMS), sorted(mz.ARCHES))
        for arch in mz.ARCHES:
            m = mm.FOLDER.fullmatch(f"ghostty-1.4.1-rc.1-windows-{arch}")
            assert m
            self.assertEqual((m["version"], m["arch"]), ("1.4.1-rc.1", arch))
        for f in mm.REQUIRED:
            if f.startswith("bin/"):
                self.assertIn(f[4:], mz.BIN)

    def test_when_is_the_latest_time(self) -> None:
        dest = self.tmp / "ghostty-1.4.1-windows-x86_64.zip"
        with zipfile.ZipFile(dest, "w") as zf:
            for i, (name, data) in enumerate(sorted(app_files().items())):
                when = (2026, 1, 2, 3, 4, 2 * i)
                zf.writestr(zipfile.ZipInfo(f"{dest.stem}/{name}", when), data)
        with zipfile.ZipFile(dest) as zf:
            app = mm.read_app(zf)
        # 2026-01-02T03:04:14Z: the eighth file's time, read as UTC.
        self.assertEqual(app.when(), 1767323054)

    def test_folder_name(self) -> None:
        for top, why in [
            ("ghostty", "not ghostty-<version>-windows-<arch>"),
            ("ghostty-1.4-windows-x86_64", "not ghostty-<version>-windows-<arch>"),
            ("ghostty-1.4.1-linux-x86_64", "not ghostty-<version>-windows-<arch>"),
            ("Ghostty-1.4.1-windows-x86_64", "not ghostty-<version>-windows-<arch>"),
            ("ghostty-1.4.1-windows-riscv64", "'riscv64' is not one of"),
        ]:
            with self.subTest(top):
                self.assertIn(why, self.refused(app_files(), top=top))

    def test_empty_zip(self) -> None:
        self.assertEqual(self.refused({}), "the zip is empty")

    def test_entries_that_are_not_the_apps_files(self) -> None:
        top = "ghostty-1.4.1-windows-x86_64"
        dest = self.tmp / f"{top}.zip"
        with zipfile.ZipFile(dest, "w") as zf:
            for name, data in app_files().items():
                zf.writestr(f"{top}/{name}", data)
            zf.writestr(f"{top}/share/empty/", b"")
            zf.writestr("other/file.txt", b"x")
            zf.writestr(f"{top}", b"x")
        with zipfile.ZipFile(dest) as zf, self.assertRaises(mm.Error) as e:
            mm.read_app(zf)
        said = str(e.exception)
        self.assertIn(f"'{top}/share/empty/' is not a file in {top}", said)
        self.assertIn(f"'other/file.txt' is not a file in {top}", said)
        self.assertIn(f"'{top}' is not a file in {top}", said)

    def test_names_windows_does_not_take(self) -> None:
        for name, why in [
            ("share/a:b", "'a:b' has a character Windows does not allow"),
            ("share/tab\there", "has a character Windows does not allow"),
            # A zip made elsewhere can hold a backslash in a name, and
            # Windows would read it as a path, here one out of the folder.
            ("share/..\\x", "'..\\\\x' has a character Windows does not allow"),
            ("share/a\\b", "'a\\\\b' has a character Windows does not allow"),
            ("share/dot./x", "'dot.' ends with a dot or a space"),
            ("share/space ", "'space ' ends with a dot or a space"),
            ("share/NUL", "'NUL' is a device's name"),
            ("share/com1.txt", "'com1.txt' is a device's name"),
            ("share/aux .d/x", "'aux .d' is a device's name"),
            ("share//x", "'' is not a name"),
            ("share/../x", "'..' is not a name"),
            # What the package cannot hold: a name that is not ASCII (a
            # device's name with a superscript digit among them), and a
            # bracket in a folder's name.
            (
                "share/Ros\u00e9 Pine",
                "'Ros\u00e9 Pine' has a character that is not ASCII",
            ),
            (
                "share/\u65e5\u672c/x",
                "'\u65e5\u672c' has a character that is not ASCII",
            ),
            ("share/COM\u00b9", "'COM\u00b9' has a character that is not ASCII"),
            ("share/a[b]/x", "folder 'a[b]' has a bracket"),
            ("share/a]/x", "folder 'a]' has a bracket"),
        ]:
            with self.subTest(name):
                self.assertIn(why, self.refused(app_files() | {name: b"x"}))
        # Not devices: a longer name, and a device's name as an extension.
        # And a file's name may have brackets.
        self.read(
            app_files()
            | {
                "share/console": b"x",
                "share/x.nul": b"x",
                "share/com10": b"x",
                "share/x[1].txt": b"x",
            }
        )

    def written(self, entries: list[tuple[zipfile.ZipInfo | str, bytes]]) -> str:
        """What read_app says of the app's files and `entries`, written
        as they are given."""
        top = "ghostty-1.4.1-windows-x86_64"
        dest = self.tmp / f"{top}.zip"
        with zipfile.ZipFile(dest, "w") as zf, warnings.catch_warnings():
            # zipfile warns of a name it has written before.
            warnings.simplefilter("ignore", UserWarning)
            for name, data in app_files().items():
                zf.writestr(zipfile.ZipInfo(f"{top}/{name}", WHEN), data)
            for entry, data in entries:
                if isinstance(entry, str):
                    entry = zipfile.ZipInfo(f"{top}/{entry}", WHEN)
                zf.writestr(entry, data)
        with zipfile.ZipFile(dest) as zf, self.assertRaises(mm.Error) as e:
            mm.read_app(zf)
        return str(e.exception)

    def test_a_name_twice(self) -> None:
        # The second would be the one installed, and another program
        # may unpack the first.
        self.assertEqual(
            self.written([("README.txt", b"another\n"), ("share/x", b"x")]),
            "the zip is not an app zip:\n  'README.txt' is in the zip twice",
        )

    def test_a_symbolic_link(self) -> None:
        link = zipfile.ZipInfo("ghostty-1.4.1-windows-x86_64/share/link", WHEN)
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        self.assertEqual(
            self.written([(link, b"ghostty/themes")]),
            "the zip is not an app zip:\n  'share/link' is a symbolic link",
        )

    def test_a_time_that_is_no_date(self) -> None:
        # All zeros is how some programs write "no time": 1980, month 0.
        for when in [
            (1980, 0, 0, 0, 0, 0),
            (2026, 1, 0, 0, 0, 0),
            (2026, 13, 1, 0, 0, 0),
        ]:
            with self.subTest(when):
                entry = zipfile.ZipInfo("ghostty-1.4.1-windows-x86_64/share/x", when)
                self.assertEqual(
                    self.written([(entry, b"x")]),
                    "the zip is not an app zip:\n"
                    f"  'share/x' has a time that is no date: {when}",
                )

    def test_names_that_differ_only_in_case(self) -> None:
        for extra, why in [
            ({"readme.TXT": b"x"}, "file readme.TXT and file README.txt are one name"),
            ({"Share/x": b"x"}, "folder share and folder Share are one name"),
            ({"BIN": b"x"}, "folder bin and file BIN are one name"),
        ]:
            with self.subTest(sorted(extra)):
                self.assertIn(why, self.refused(app_files() | extra))

    def test_missing_files(self) -> None:
        # Spelled out: what the package points at, and the two texts.
        for f in (
            "bin/ghostty.exe",
            "bin/ghostty.com",
            "share/icons/hicolor/256x256/apps/com.mitchellh.ghostty.png",
            "README.txt",
            "LICENSE.txt",
        ):
            with self.subTest(f):
                files = app_files()
                del files[f]
                self.assertIn(f"{f} is missing", self.refused(files))

    def test_every_problem_is_listed_once(self) -> None:
        files = app_files() | {"share/a:b/x": b"x", "share/a:b/y": b"x"}
        del files["README.txt"]
        said = self.refused(files)
        self.assertEqual(said.count("has a character Windows does not allow"), 2)
        self.assertEqual(said.count("README.txt is missing"), 1)
        # Each file under share meets the folder Share again.
        said = self.refused(app_files() | {"Share/x": b"x"})
        self.assertEqual(said.count("folder share and folder Share are one name"), 1)


class TestVersion(unittest.TestCase):
    def test_first_three_numbers(self) -> None:
        for version, expected in [
            ("1.4.1", "1.4.1"),
            ("1.4.1-dev", "1.4.1"),
            ("1.4.1-rc.2+abc123", "1.4.1"),
            ("0.0.0", "0.0.0"),
            ("255.255.65535", "255.255.65535"),
        ]:
            with self.subTest(version):
                self.assertEqual(mm.product_version(version), expected)

    def test_numbers_a_package_cannot_hold(self) -> None:
        for version in ["256.0.0", "1.256.0", "1.0.65536"]:
            with self.subTest(version), self.assertRaises(mm.Error) as e:
                mm.product_version(version)
            self.assertIn("at most 255.255.65535", str(e.exception))


class TestCodes(unittest.TestCase):
    """What must stay as it is for an upgrade to find the installed
    Ghostty and for a component to stay the same component."""

    def test_codes_that_never_change(self) -> None:
        self.assertEqual(mm.UPGRADE_CODE, "35E4D04C-BBFB-4011-AAE3-B8C729AB8B7A")
        self.assertEqual(mm.guid("folder", "."), "0C5DB17D-5CFF-598A-AD52-C26C149C782D")
        self.assertEqual(
            mm.guid("folder", "bin"), "E0C557DD-6414-5D80-9ACE-A5280EEFB928"
        )
        self.assertEqual(mm.guid("start menu"), "A6AF273D-3981-5ABB-AAF8-423B548BBA47")

    def test_guid_depends_on_every_part(self) -> None:
        seen = {
            mm.guid("folder", "bin"),
            mm.guid("folder", "share"),
            mm.guid("folder", "share\\bin"),
            mm.guid("folder\nshare", "bin"),
            mm.guid("product", "bin"),
        }
        # "folder", "share\nbin" and "folder\nshare", "bin" are one text.
        self.assertEqual(len(seen), 5)
        self.assertRegex(mm.guid("x"), r"^[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}$")


class TestSource(Temp):
    def source(
        self,
        files: dict[str, bytes],
        code: str = "1" * 8 + "-1111-1111-1111-" + "1" * 12,
    ):
        return ElementTree.fromstring(mm.source(self.read(files), code))

    def components(self, root: ElementTree.Element) -> dict[str, ElementTree.Element]:
        """Each component by the name of its key path's value."""
        out = {}
        for c in root.iter(f"{WIX}Component"):
            values = [v for v in c.findall(f"{WIX}RegistryValue") if v.get("KeyPath")]
            self.assertEqual(len(values), 1)
            self.assertEqual(
                (values[0].get("Root"), values[0].get("Key"), values[0].get("KeyPath")),
                ("HKCU", r"Software\Pyre909\Ghostty\Installed", "yes"),
            )
            out[values[0].get("Name")] = c
        return out

    def test_one_component_a_folder(self) -> None:
        root = self.source(app_files())
        components = self.components(root)
        self.assertEqual(sorted(components), sorted([*FOLDERS, "Start menu"]))
        for name, c in components.items():
            with self.subTest(name):
                # A folder in a profile goes only when the package says.
                removes = c.findall(f"{WIX}RemoveFolder")
                self.assertEqual(len(removes), 0 if name == "Start menu" else 1)
        files = {
            name: sorted(f.get("Source") for f in c.findall(f"{WIX}File"))
            for name, c in components.items()
        }
        self.assertEqual(
            files["."],
            ["tree/LICENSE.txt", "tree/README.txt", "tree/THIRD-PARTY-NOTICES.txt"],
        )
        self.assertEqual(files["bin"], ["tree/bin/ghostty.com", "tree/bin/ghostty.exe"])
        self.assertEqual(files["share"], [])
        self.assertEqual(
            files[r"share\ghostty\themes"], ["tree/share/ghostty/themes/3024 Day"]
        )
        self.assertEqual(
            sum(len(v) for v in files.values()), len(app_files()), "every file once"
        )
        # Ids are unique, and the one feature installs every component.
        ids = [e.get("Id") for e in root.iter() if e.tag != f"{WIX}ComponentRef"]
        ids = [i for i in ids if i]
        self.assertEqual(len(ids), len(set(ids)))
        refs = sorted(r.get("Id") for r in root.iter(f"{WIX}ComponentRef"))
        self.assertEqual(refs, sorted(c.get("Id") for c in components.values()))

    def test_folders_nest_as_in_the_zip(self) -> None:
        root = self.source(app_files())

        parents = {c: p for p in root.iter() for c in p}

        def path_of(directory_id: str | None) -> list[str | None]:
            e = next(
                d for d in root.iter(f"{WIX}Directory") if d.get("Id") == directory_id
            )
            out = []
            while e.tag == f"{WIX}Directory":
                out.append(e.get("Name") or e.get("Id"))
                e = parents[e]
            return out[::-1]

        x = self.components(root)[r"share\terminfo\x"]
        self.assertEqual(
            path_of(parents[x].get("Id")),
            [
                "SourceDir",
                "LocalAppDataFolder",
                "Programs",
                "Ghostty",
                "share",
                "terminfo",
                "x",
            ],
        )
        menu = self.components(root)["Start menu"]
        self.assertEqual(
            path_of(parents[menu].get("Id")), ["SourceDir", "ProgramMenuFolder"]
        )
        # The shortcut points at ghostty.exe in the bin folder.
        (shortcut,) = root.iter(f"{WIX}Shortcut")
        bin_dir = parents[self.components(root)["bin"]].get("Id")
        self.assertEqual(shortcut.get("Target"), f"[{bin_dir}]ghostty.exe")
        self.assertEqual(shortcut.get("Name"), "Ghostty")
        self.assertIsNone(shortcut.get("WorkingDirectory"))
        self.assertIsNone(shortcut.get("Advertise"))

    def test_a_folder_keeps_its_component(self) -> None:
        # Another version has other folders, which shift the ids; a
        # folder's component GUID must not move with them.
        before = self.components(self.source(app_files()))
        files = app_files() | {"a/first": b"x", "share/ghostty/doc/x": b"x"}
        after = self.components(self.source(files))
        self.assertNotEqual(before["bin"].get("Id"), after["bin"].get("Id"))
        for name in before:
            with self.subTest(name):
                self.assertEqual(before[name].get("Guid"), after[name].get("Guid"))
        guids = [c.get("Guid") for c in after.values()]
        self.assertEqual(len(guids), len(set(guids)))

    def test_for_the_current_user(self) -> None:
        root = self.source(app_files())
        (product,) = root.iter(f"{WIX}Product")
        self.assertEqual(product.get("UpgradeCode"), mm.UPGRADE_CODE)
        self.assertEqual(product.get("Id"), "11111111-1111-1111-1111-111111111111")
        self.assertEqual(product.get("Version"), "1.4.1")
        (package,) = root.iter(f"{WIX}Package")
        self.assertEqual(package.get("InstallScope"), "perUser")
        self.assertEqual(package.get("InstallerVersion"), "500")
        (upgrade,) = root.iter(f"{WIX}MajorUpgrade")
        self.assertEqual(upgrade.get("AllowSameVersionUpgrades"), "yes")
        # Nothing asks for the machine's hive or for all users.
        self.assertEqual(
            {v.get("Root") for v in root.iter(f"{WIX}RegistryValue")}, {"HKCU"}
        )
        properties = {p.get("Id"): p.get("Value") for p in root.iter(f"{WIX}Property")}
        self.assertNotIn("ALLUSERS", properties)
        self.assertEqual(
            properties["ARPURLINFOABOUT"], "https://github.com/Pyre909/ghostty"
        )
        self.assertIn("unofficial build", properties["ARPCOMMENTS"])
        # wixl writes the PATH entry wrongly: it is added to the package.
        self.assertEqual(list(root.iter(f"{WIX}Environment")), [])


class TestTimes(Temp):
    def package(self, *seconds: int) -> Path:
        path = self.tmp / "x.msi"
        parts = [b"head"]
        for s in seconds:
            parts += [(64).to_bytes(4, "little") + mm.filetime(s), b"between"]
        path.write_bytes(b"".join(parts))
        return path

    def test_filetime(self) -> None:
        # 1970 is 11644473600 s after 1601.
        self.assertEqual(int.from_bytes(mm.filetime(0), "little"), 116444736000000000)
        self.assertEqual(int.from_bytes(mm.filetime(1), "little"), 116444736010000000)

    def test_replaces_the_two_times(self) -> None:
        now = int(time.time())
        path = self.package(now, now)
        mm.set_times(path, now, 86400)
        stamp = (64).to_bytes(4, "little") + mm.filetime(86400)
        self.assertEqual(path.read_bytes(), b"head" + (stamp + b"between") * 2)

    def test_a_second_apart(self) -> None:
        now = int(time.time())
        path = self.package(now - 1, now + 1)
        mm.set_times(path, now, 86400)
        self.assertEqual(path.read_bytes().count(mm.filetime(86400)), 2)

    def test_anything_but_two_fails(self) -> None:
        now = int(time.time())
        for seconds in [(), (now,), (now, now, now), (now, now - 3600)]:
            with self.subTest(len(seconds)):
                path = self.package(*seconds)
                was = path.read_bytes()
                with self.assertRaises(mm.Error) as e:
                    mm.set_times(path, now, 86400)
                self.assertRegex(str(e.exception), r"found \d times .* not 2")
                self.assertEqual(path.read_bytes(), was)


class TestPackage(unittest.TestCase):
    """Packages built for real: one of each architecture, the x86_64 one
    twice, and one of a zip with another file."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.tools = tools()
        tmp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(tmp.cleanup)
        cls.tmp = Path(tmp.name)
        cls.zip = app_zip(cls.tmp / "zip")
        cls.x64 = build(cls.zip, cls.tmp / "x64")
        cls.arm = build(app_zip(cls.tmp / "zip", arch="aarch64"), cls.tmp / "arm")
        # wixl records the second it ran: a later second, another package,
        # unless make_msi.py takes the time out.
        time.sleep(1.1)
        cls.again = build(cls.zip, cls.tmp / "again")
        cls.other = build(
            app_zip(cls.tmp / "other", app_files() | {"share/new": b"x"}),
            cls.tmp / "other",
        )

    def table(self, msi: Path, name: str) -> list[dict[str, str]]:
        return mm.table(self.tools, msi, name)

    def property(self, msi: Path, name: str) -> str | None:
        return {r["Property"]: r["Value"] for r in self.table(msi, "Property")}.get(
            name
        )

    def test_named_after_the_zip(self) -> None:
        self.assertEqual(self.x64.name, "ghostty-1.4.1-windows-x86_64.msi")
        self.assertEqual(self.arm.name, "ghostty-1.4.1-windows-aarch64.msi")
        # Nothing else is left beside it: no stage, no source.
        self.assertEqual([p.name for p in self.x64.parent.iterdir()], [self.x64.name])

    def test_reproducible(self) -> None:
        self.assertEqual(self.x64.read_bytes(), self.again.read_bytes())

    def test_platform(self) -> None:
        self.assertEqual(mm.summary(self.tools, self.x64)["Template"], "x64;1033")
        self.assertEqual(mm.summary(self.tools, self.arm)["Template"], "Arm64;1033")

    def test_summary(self) -> None:
        info = mm.summary(self.tools, self.arm)
        # mm.run reads it in UTC; the zip's time, not the build's.
        self.assertEqual(info["Created"], "Fri Jan  2 03:04:06 2026")
        self.assertEqual(info["Last saved"], "Fri Jan  2 03:04:06 2026")
        # 500: the first schema with Arm64. 10: compressed, no elevation.
        self.assertEqual(info["Version"].split(" ")[0], "500")
        self.assertEqual(info["Source"].split(" ")[0], "10")
        self.assertEqual(info["Author"], "Pyre909")
        self.assertIn("unofficial build", info["Subject"])
        self.assertIn("(1.4.1, aarch64)", info["Subject"])

    def test_codes(self) -> None:
        codes = {}
        for msi in (self.x64, self.arm, self.other):
            self.assertEqual(
                self.property(msi, "UpgradeCode"), "{" + mm.UPGRADE_CODE + "}"
            )
            self.assertEqual(self.property(msi, "ProductVersion"), "1.4.1")
            self.assertIsNone(self.property(msi, "ALLUSERS"))
            codes[msi] = (
                self.property(msi, "ProductCode"),
                mm.summary(self.tools, msi)["Revision number (UUID)"],
            )
            for code in codes[msi]:
                self.assertRegex(code or "", r"^\{[0-9A-F-]{36}\}$")
        # Another architecture or another file: another product, and a
        # product's code is not its package's.
        self.assertEqual(len({c for pair in codes.values() for c in pair}), 6)

    def test_codes_depend_on_the_bytes(self) -> None:
        def codes(msi: Path) -> tuple[str | None, str]:
            return (
                self.property(msi, "ProductCode"),
                mm.summary(self.tools, msi)["Revision number (UUID)"],
            )

        # The same names, and so the same source, with another README.
        files = app_files() | {"README.txt": b"another readme\n"}
        other = build(app_zip(self.tmp / "bytes", files), self.tmp / "bytes")
        icon = self.tmp / "other.ico"
        icon.write_bytes(mm.ICON.read_bytes() + b"\0")
        with mock.patch.object(mm, "ICON", icon):
            iconed = build(self.zip, self.tmp / "icon")
        # And what this script writes into the package: the same zip
        # and icon, with another link in the Apps list.
        with mock.patch.object(mm, "HOMEPAGE", "https://example.invalid/ghostty"):
            linked = build(self.zip, self.tmp / "link")
        self.assertEqual(
            self.property(linked, "ARPURLINFOABOUT"), "https://example.invalid/ghostty"
        )
        # What it adds to the package wixl compiled: an action a place
        # later.
        actions = mm.ENVIRONMENT_ACTIONS | {"WriteEnvironmentStrings": 5201}
        with mock.patch.object(mm, "ENVIRONMENT_ACTIONS", actions):
            added = build(self.zip, self.tmp / "added")
        sequence = {
            r["Action"]: r["Sequence"]
            for r in self.table(added, "InstallExecuteSequence")
        }
        self.assertEqual(sequence["WriteEnvironmentStrings"], "5201")
        # And the msitools that made it.
        real = mm.run

        def run(cmd: list[str], cwd: Path) -> str:
            return "0.0\n" if cmd[1:] == ["--version"] else real(cmd, cwd)

        with mock.patch.object(mm, "run", side_effect=run):
            tooled = build(self.zip, self.tmp / "tooled")
        packages = (self.x64, other, iconed, linked, added, tooled)
        seen = {c for msi in packages for c in codes(msi)}
        self.assertEqual(len(seen), 2 * len(packages))

    def test_replaces_same_and_older_and_refuses_newer(self) -> None:
        rows = self.table(self.x64, "Upgrade")
        self.assertEqual(
            {r["UpgradeCode"] for r in rows}, {"{" + mm.UPGRADE_CODE + "}"}
        )
        self.assertEqual(
            {
                r["ActionProperty"]: (
                    r["VersionMin"],
                    r["VersionMax"],
                    int(r["Attributes"]),
                )
                for r in rows
            },
            {
                # 1: what is found is removed, and its features kept.
                "WIX_UPGRADE_DETECTED": ("", "1.4.1", 1),
                # 256 and 512: from this very version, and up to it.
                "WIX_SAME_VERSION_UPGRADE_DETECTED": ("1.4.1", "1.4.1", 1 + 256 + 512),
                # 2: only found, for the condition below.
                "WIX_DOWNGRADE_DETECTED": ("1.4.1", "", 2),
            },
        )
        (condition,) = self.table(self.x64, "LaunchCondition")
        self.assertEqual(
            (condition["Condition"], condition["Description"]),
            (
                "NOT WIX_DOWNGRADE_DETECTED",
                "A newer version of Ghostty is already installed.",
            ),
        )

    def test_apps_entry(self) -> None:
        for msi in (self.x64, self.arm):
            with self.subTest(msi.name):
                self.assertEqual(self.property(msi, "ARPPRODUCTICON"), "ghostty.ico")
                streams = subprocess.run(
                    [self.tools["msiinfo"], "streams", str(msi)],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout.split()
                self.assertIn("Icon.ghostty.ico", streams)
                self.assertEqual(
                    self.property(msi, "ARPURLINFOABOUT"),
                    "https://github.com/Pyre909/ghostty",
                )
                self.assertIn(
                    "unofficial build", self.property(msi, "ARPCOMMENTS") or ""
                )
                # No Change button: there is one feature.
                self.assertEqual(self.property(msi, "ARPNOMODIFY"), "1")

    def test_leaves_closing_ghostty_to_its_user(self) -> None:
        # What the property does is Windows Installer's, and is measured
        # on Windows; here, that both packages carry it.
        for msi in (self.x64, self.arm):
            self.assertEqual(
                self.property(msi, "MSIRESTARTMANAGERCONTROL"), "DisableShutdown"
            )

    def test_path_entry(self) -> None:
        components = {
            r["Directory_"]: r["Component"] for r in self.table(self.arm, "Component")
        }
        directories = {r["Directory"]: r for r in self.table(self.arm, "Directory")}
        (row,) = self.table(self.arm, "Environment")
        # "=-": set for the user, removed again on uninstall; "[~];": what
        # the variable held stays in front.
        self.assertEqual((row["Name"], row["Value"][:5]), ("=-PATH", "[~];["))
        folder = row["Value"][5:-1]
        self.assertEqual(directories[folder]["DefaultDir"].rpartition("|")[2], "bin")
        self.assertEqual(row["Component_"], components[folder])
        sequence = {
            r["Action"]: int(r["Sequence"])
            for r in self.table(self.arm, "InstallExecuteSequence")
        }
        # Removed before the files go, written after they are there, and
        # both between InstallInitialize and InstallFinalize.
        self.assertLess(
            sequence["InstallInitialize"], sequence["RemoveEnvironmentStrings"]
        )
        self.assertLess(sequence["RemoveEnvironmentStrings"], sequence["RemoveFiles"])
        self.assertLess(sequence["InstallFiles"], sequence["WriteEnvironmentStrings"])
        self.assertLess(
            sequence["WriteEnvironmentStrings"], sequence["InstallFinalize"]
        )

    def test_registry(self) -> None:
        rows = self.table(self.x64, "Registry")
        self.assertEqual({r["Root"] for r in rows}, {"1"}, "the user's hive only")
        own = sorted(r["Name"] for r in rows if r["Key"] == mm.KEY)
        self.assertEqual(own, sorted([*FOLDERS, "Start menu"]))
        toast = {r["Name"]: r for r in rows if r["Key"] != mm.KEY}
        self.assertEqual(
            {r["Key"] for r in toast.values()},
            {r"Software\Classes\AppUserModelId\com.mitchellh.ghostty"},
        )
        # What Ghostty registers there itself: the name its notifications
        # show and their icon, by the path the file is installed at. And
        # a name of "-" without a value, which deletes the key on
        # uninstall.
        (icon,) = [
            r["File"]
            for r in self.table(self.x64, "File")
            if r["FileName"].rpartition("|")[2] == "com.mitchellh.ghostty.png"
        ]
        self.assertEqual(
            {name: r["Value"] for name, r in toast.items()},
            {"DisplayName": "Ghostty", "IconUri": f"[#{icon}]", "-": ""},
        )
        top = {
            r["Directory_"]: r["Component"] for r in self.table(self.x64, "Component")
        }
        ghostty = [
            r["Directory"]
            for r in self.table(self.x64, "Directory")
            if r["DefaultDir"].rpartition("|")[2] == "Ghostty"
        ]
        self.assertEqual({r["Component_"] for r in toast.values()}, {top[ghostty[0]]})

    def test_files(self) -> None:
        names = sorted(
            r["FileName"].rpartition("|")[2] for r in self.table(self.x64, "File")
        )
        self.assertEqual(names, sorted(f.rpartition("/")[2] for f in app_files()))
        sizes = {
            r["FileName"].rpartition("|")[2]: int(r["FileSize"])
            for r in self.table(self.x64, "File")
        }
        self.assertEqual(
            sizes["3024 Day"], len(app_files()["share/ghostty/themes/3024 Day"])
        )
        # One folder to remove per folder installed.
        removes = self.table(self.x64, "RemoveFile")
        self.assertEqual(len(removes), len(FOLDERS))
        self.assertEqual({r["FileName"] for r in removes}, {""})
        self.assertEqual({r["InstallMode"] for r in removes}, {"2"})

    def test_files_have_the_zips_times(self) -> None:
        # A zip whose files each have a time of their own.
        top = "ghostty-1.4.1-windows-x86_64"
        (self.tmp / "times").mkdir()
        dest = self.tmp / "times" / f"{top}.zip"
        expected = {}
        with zipfile.ZipFile(dest, "w") as zf:
            for i, (name, data) in enumerate(sorted(app_files().items())):
                when = (2026, 1, 2, 3, 4, 2 * i)
                zf.writestr(zipfile.ZipInfo(f"{top}/{name}", when), data)
                expected[name.rpartition("/")[2]] = when
        msi = build(dest, self.tmp / "times")
        # The cabinet's entries are named by the File table's keys. Each
        # is 16 bytes, among them a date and a time as MS-DOS packs them,
        # then its name; the header has where they start and how many.
        names = {
            r["File"]: r["FileName"].rpartition("|")[2] for r in self.table(msi, "File")
        }
        cab = subprocess.run(
            [self.tools["msiinfo"], "extract", str(msi), "cab1.cab"],
            check=True,
            capture_output=True,
        ).stdout
        self.assertEqual(cab[:4], b"MSCF")
        at = int.from_bytes(cab[16:20], "little")
        got = {}
        for _ in range(int.from_bytes(cab[28:30], "little")):
            date = int.from_bytes(cab[at + 10 : at + 12], "little")
            clock = int.from_bytes(cab[at + 12 : at + 14], "little")
            end = cab.index(b"\0", at + 16)
            got[names[cab[at + 16 : end].decode("ascii")]] = (
                (date >> 9) + 1980,
                date >> 5 & 15,
                date & 31,
                clock >> 11,
                clock >> 5 & 63,
                (clock & 31) * 2,
            )
            at = end + 1
        self.assertEqual(got, expected)
        # And the package says it was made at the latest of them.
        self.assertEqual(
            mm.summary(self.tools, msi)["Created"], "Fri Jan  2 03:04:14 2026"
        )

    def test_shortcut(self) -> None:
        (row,) = self.table(self.x64, "Shortcut")
        self.assertEqual(row["Directory_"], "ProgramMenuFolder")
        self.assertEqual(row["Name"].rpartition("|")[2], "Ghostty")
        self.assertRegex(row["Target"], r"^\[dir\d+\]ghostty\.exe$")
        self.assertEqual(row["WkDir"], "")

    def test_package_wixl_compiled_is_not_enough(self) -> None:
        # Without make_msi.py's own edits the package fails its check on
        # each of them: the check reads the package, not the script.
        with mock.patch.object(mm, "finish"):
            said = fails(
                app_zip(self.tmp / "zip", arch="aarch64"), self.tmp / "unfinished"
            )
        for what in [
            "the platform is 'x64;1033', not 'Arm64;1033'",
            "the creation time is",
            "the last-saved time is",
            "the package code is",
            "the environment is [], not",
            "RemoveEnvironmentStrings's place is None, not 3300",
            "WriteEnvironmentStrings's place is None, not 5200",
            # The two values are in the source; the key's removal is not.
            "the notification key's rows is [('DisplayName', 'Ghostty', 'cmp0'), ('IconUri', ",
        ]:
            with self.subTest(what):
                self.assertIn(what, said)
        self.assertEqual(
            list((self.tmp / "unfinished").iterdir()), [], "nothing is published"
        )


class TestCheck(Temp):
    """The check a package passes before it is published, given packages
    changed after they were built."""

    def test_a_changed_package_fails_on_the_change(self) -> None:
        found = tools()
        z = app_zip(self.tmp / "zip")
        good = build(z, self.tmp / "out")
        with zipfile.ZipFile(z) as zf:
            app = mm.read_app(zf)
        properties = {
            r["Property"]: r["Value"] for r in mm.table(found, good, "Property")
        }
        product = properties["ProductCode"].strip("{}")
        package = mm.summary(found, good)["Revision number (UUID)"].strip("{}")
        mm.check(found, good, app, product, package)
        files = {
            r["FileName"].rpartition("|")[2]: r["File"]
            for r in mm.table(found, good, "File")
        }
        folders = {
            r["DefaultDir"].rpartition("|")[2]: r["Directory"]
            for r in mm.table(found, good, "Directory")
        }
        components = {
            r["Directory_"]: r["Component"] for r in mm.table(found, good, "Component")
        }
        top, bin_dir = folders["Ghostty"], folders["bin"]
        for n, (statement, problem) in enumerate(
            [
                (
                    "INSERT INTO `Property` (`Property`, `Value`) VALUES ('ALLUSERS', '2')",
                    "ALLUSERS is '2', not None",
                ),
                (
                    "UPDATE `Property` SET `Value` = '1.4.2' WHERE `Property` = 'ProductVersion'",
                    "ProductVersion is '1.4.2', not '1.4.1'",
                ),
                (
                    "UPDATE `Property` SET `Value` = '{1}' WHERE `Property` = 'ProductCode'",
                    "ProductCode is '{1}', not '{" + product + "}'",
                ),
                (
                    "UPDATE `Property` SET `Value` = '{2}' WHERE `Property` = 'UpgradeCode'",
                    "UpgradeCode is '{2}', not '{" + mm.UPGRADE_CODE + "}'",
                ),
                # The machine's hive, which needs an administrator.
                (
                    "UPDATE `Registry` SET `Root` = 2",
                    "the registry roots is {'2'}, not {'1'}",
                ),
                # Another folder than the one under the user's programs.
                (
                    "UPDATE `Directory` SET `Directory_Parent` = 'TARGETDIR' WHERE `Directory` = 'UserPrograms'",
                    "where it installs is [('TARGETDIR', 'Programs'), ('UserPrograms', 'Ghostty')], not [('LocalAppDataFolder', ",
                ),
                # The files: one gone, one in another folder, and one of
                # another size than the zip's.
                (
                    f"DELETE FROM `File` WHERE `File` = '{files['LICENSE.txt']}'",
                    "the package's files and the zip's differ in [('LICENSE.txt', 8)]",
                ),
                (
                    f"UPDATE `File` SET `Component_` = '{components[bin_dir]}' WHERE `File` = '{files['README.txt']}'",
                    "the package's files and the zip's differ in [('bin/README.txt', 7), ('README.txt', 7)]",
                ),
                (
                    f"UPDATE `File` SET `FileSize` = 9 WHERE `File` = '{files['ghostty.exe']}'",
                    "the package's files and the zip's differ in [('bin/ghostty.exe', 9), ('bin/ghostty.exe', 88)]",
                ),
                # What make_msi.py adds to the package, there but wrong:
                # the PATH entry of another folder, or removed with
                # another folder's component, an action out of its
                # place, and a notification key that is made, not
                # deleted.
                (
                    f"UPDATE `Environment` SET `Value` = '[~];[{top}]'",
                    f"the environment is [('UserPath', '=-PATH', '[~];[{top}]', ",
                ),
                (
                    f"UPDATE `Environment` SET `Component_` = '{components[top]}'",
                    f"the environment is [('UserPath', '=-PATH', '[~];[{bin_dir}]', '{components[top]}')], not ",
                ),
                (
                    "UPDATE `InstallExecuteSequence` SET `Sequence` = 6600 WHERE `Action` = 'RemoveEnvironmentStrings'",
                    "RemoveEnvironmentStrings's place is 6600, not 3300",
                ),
                (
                    "UPDATE `InstallExecuteSequence` SET `Sequence` = 1 WHERE `Action` = 'WriteEnvironmentStrings'",
                    "WriteEnvironmentStrings's place is 1, not 5200",
                ),
                (
                    "UPDATE `Registry` SET `Name` = '+' WHERE `Registry` = 'regToast'",
                    "the notification key's rows is [('+', '', ",
                ),
                (
                    f"UPDATE `Registry` SET `Component_` = '{components[bin_dir]}' WHERE `Registry` = 'regToast'",
                    f"the notification key's rows is [('-', '', '{components[bin_dir]}'), ",
                ),
                # And what it registers there: another name, and an icon
                # that is another file.
                (
                    "UPDATE `Registry` SET `Value` = 'Other' WHERE `Name` = 'DisplayName'",
                    "the notification key's rows is [('-', '', 'cmp0'), ('DisplayName', 'Other', ",
                ),
                (
                    f"UPDATE `Registry` SET `Value` = '[#{files['README.txt']}]' WHERE `Name` = 'IconUri'",
                    f"('IconUri', '[#{files['README.txt']}]', 'cmp0')], not ",
                ),
            ]
        ):
            with self.subTest(problem):
                changed = self.tmp / f"changed{n}.msi"
                shutil.copyfile(good, changed)
                subprocess.run(
                    [found["msibuild"], str(changed), "-q", statement], check=True
                )
                with self.assertRaises(mm.Error) as raised:
                    mm.check(found, changed, app, product, package)
                said = str(raised.exception)
                self.assertIn(problem, said)
                self.assertEqual(said.count("\n  "), 1, said)
        # The summary's two numbers cannot be changed with msitools, so
        # here the check is told of other ones.
        real = mm.summary(found, good)
        for key, value, problem in [
            ("Version", "200 (c8)", "the schema is '200', not '500'"),
            # 2 alone: compressed, and an administrator needed.
            ("Source", "2 (2)", "the source type is '2', not '10'"),
        ]:
            with (
                self.subTest(problem),
                mock.patch.object(mm, "summary", return_value=real | {key: value}),
            ):
                with self.assertRaises(mm.Error) as raised:
                    mm.check(found, good, app, product, package)
                self.assertEqual(
                    str(raised.exception), f"the package is not as meant:\n  {problem}"
                )


class TestRefusals(Temp):
    def test_exe_of_another_architecture(self) -> None:
        z = app_zip(self.tmp, app_files("aarch64"), arch="x86_64")
        self.assertEqual(
            fails(z, self.tmp / "out"),
            "make_msi: bin/ghostty.exe is 0xaa64, not x86_64\n",
        )
        z = app_zip(self.tmp, app_files() | {"bin/ghostty.exe": b"exe"})
        self.assertEqual(
            fails(z, self.tmp / "out"),
            "make_msi: bin/ghostty.exe is not a PE file, not x86_64\n",
        )

    def test_not_an_app_zip(self) -> None:
        files = app_files()
        del files["LICENSE.txt"]
        self.assertEqual(
            fails(app_zip(self.tmp, files), self.tmp / "out"),
            "make_msi: the zip is not an app zip:\n  LICENSE.txt is missing\n",
        )
        self.assertIn("is not a file", fails(self.tmp / "none.zip", self.tmp / "out"))
        text = self.tmp / "text.zip"
        text.write_text("not a zip\n")
        self.assertEqual(
            fails(text, self.tmp / "out"),
            f"make_msi: {text}: File is not a zip file\n",
        )

    def test_version_a_package_cannot_hold(self) -> None:
        z = app_zip(self.tmp, version="1.300.0")
        self.assertIn(
            "1.300.0: a package's version holds at most", fails(z, self.tmp / "out")
        )
        self.assertEqual(list((self.tmp / "out").iterdir()), [])

    def test_without_msitools(self) -> None:
        with mock.patch.object(shutil, "which", return_value=None):
            self.assertEqual(
                fails(app_zip(self.tmp), self.tmp / "out"),
                "make_msi: wixl is not on PATH; it is part of msitools\n",
            )

    def test_failed_tool(self) -> None:
        tools()
        real = shutil.which

        def which(tool: str) -> str | None:
            return real("false") if tool == "msibuild" else real(tool)

        with mock.patch.object(shutil, "which", side_effect=which):
            said = fails(app_zip(self.tmp), self.tmp / "out")
        self.assertRegex(
            said, r"^make_msi: \S*false \S+\.msi -q 'INSERT INTO `Environment`"
        )
        self.assertIn("' failed with exit status 1:\n", said)
        self.assertEqual(list((self.tmp / "out").iterdir()), [], "nothing is published")


class TestRepository(unittest.TestCase):
    """What make_msi.py says of the rest of the repository."""

    def test_notification_key_is_ghosttys_app_id(self) -> None:
        config = (REPO / "src/build_config.zig").read_text("utf-8")
        (bundle_id,) = re.findall(
            r'^pub const bundle_id = "([^"]+)";$', config, re.MULTILINE
        )
        self.assertEqual(mm.TOAST_KEY, rf"Software\Classes\AppUserModelId\{bundle_id}")
        # A release build's app ID is that id, and that is where it is
        # registered.
        toast = (REPO / "src/apprt/windows/toast.zig").read_text("utf-8")
        self.assertIn("    .fast, .small => build_config.bundle_id,\n", toast)
        self.assertIn(r'"Software\\Classes\\AppUserModelId\\{s}"', toast)

    def test_registers_what_ghostty_registers(self) -> None:
        # The two values `register` writes, the name a release build
        # gives the first, and the icon's path under share, which
        # `iconPath` ends with the bundle id.
        toast = (REPO / "src/apprt/windows/toast.zig").read_text("utf-8")
        register = toast[toast.index("\npub fn register(") :]
        register = register[: register.index("\n}\n")]
        values = re.findall(r'utf8ToUtf16LeStringLiteral\("(\w+)"\)', register)
        self.assertEqual(sorted(set(values)), ["DisplayName", "IconUri"])
        self.assertIn(f'    .fast, .small => "{mm.TOAST_NAME}",\n', toast)
        (under_share,) = re.findall(r'"\{s\}((?:\\\\\w+)+)\\\\\{s\}\.png"', toast)
        config = (REPO / "src/build_config.zig").read_text("utf-8")
        (bundle_id,) = re.findall(
            r'^pub const bundle_id = "([^"]+)";$', config, re.MULTILINE
        )
        self.assertEqual(
            mm.TOAST_ICON,
            "share" + under_share.replace("\\\\", "/") + f"/{bundle_id}.png",
        )

    def test_icon(self) -> None:
        self.assertEqual(mm.ICON.read_bytes()[:4], b"\0\0\1\0", "an .ico file")

    def test_readme_tells_of_both_packages(self) -> None:
        readme = (REPO / "dist/windows/README.txt").read_text("utf-8")
        self.assertIn("unofficial build", readme)
        self.assertIn(mm.HOMEPAGE, readme)
        self.assertIn(r"%LOCALAPPDATA%\Programs\Ghostty", readme)
        self.assertIn("\nPortable zip\n", readme)
        self.assertIn("\nInstaller\n", readme)
        # A command as each package's user types it: the installer puts
        # bin on the PATH, and the zip does not.
        self.assertIn("\nghostty +crash-report lists them", readme)
        self.assertIn(r"bin\ghostty +crash-report", readme)


if __name__ == "__main__":
    unittest.main()
