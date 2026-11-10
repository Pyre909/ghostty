"""
Builds Ghostty's Windows installer from an app zip that make_zip.py made.

    python3 dist/windows/make_msi.py zig-out/dist/ghostty-1.4.1-windows-x86_64.zip

writes ghostty-1.4.1-windows-x86_64.msi beside the zip (or in --out) and
prints its SHA-256 sum the way sha256sum does. The package installs what
the zip holds, file for file, so the two cannot differ, and the zip's name
for its folder gives the version and the architecture.

It needs msitools (https://gitlab.gnome.org/GNOME/msitools): wixl, which
compiles a WiX 3 source into a package on any host, and msibuild and
msiinfo, which edit and read one.

The package:

    installs for the current user only, without elevation, in
    %LOCALAPPDATA%\\Programs\\Ghostty, which is not a choice of the user's:
    an upgrade would not know of another folder;

    adds a Ghostty shortcut to the user's Start menu and the bin folder to
    the end of the user's PATH;

    is listed among the installed apps as Ghostty, by Pyre909, with the
    version's first three numbers, all a package's version can hold: a
    pre-release such as 1.4.1-dev is listed as 1.4.1;

    replaces an installed Ghostty of the same or an older version (so a
    release replaces its pre-releases, and either architecture the other)
    and refuses to install over a newer one;

    shows no pages, only Windows Installer's progress window;

    never closes an open Ghostty, whose user would lose what runs in it.
    Where it can ask (after a double click, or with msiexec /qb), it
    names the open Ghostty and asks for it to be closed first; where it
    cannot (msiexec /qn or /passive, which is how winget runs it), it
    installs around it: the open Ghostty goes on as the version it was,
    and Windows Installer moves the files it holds aside and deletes
    them at the next restart. It does not ask about an x64 Ghostty on
    Arm64 Windows either: the emulator's cache service holds that
    Ghostty's files as well, the Restart Manager lists the service as a
    critical application, and Windows Installer then installs around
    the open Ghostty whatever window it has;

    when uninstalled, removes what it installed, and the app ID that
    Ghostty registers for its notifications the first time it shows one
    (src/apprt/windows/toast.zig). It leaves what Ghostty wrote in
    %LOCALAPPDATA%\\ghostty: the configuration, the crash dumps.

Each folder is one component, with a value under
HKCU\\Software\\Pyre909\\Ghostty\\Installed as its key path, as Windows
Installer asks of components in a user's profile, and a component's GUID
depends only on its folder's path, so that it stays the same from version
to version. The product and package codes depend on the zip's and the
icon's bytes and on the source generated here: the same zip gives the
same product, and anything else another one, which the upgrade code,
the same for every package, lets replace the installed one.

The package is reproducible: two runs on the same zip with the same
msitools give the same bytes. Its files have the times they have in the
zip, and its summary says it was created at the latest of them.

wixl 0.106 cannot write all of that, so the package it compiles is edited
(`finish`) and then read back and checked (`check`):

    it knows no Arm64 packages, so every package is compiled as x64, the
    other 64-bit platform, and an aarch64 one's platform is then set in
    its summary;

    it writes the PATH entry of `Permanent="no"` as one that an uninstall
    leaves behind (and that of `Permanent="yes"` as one it removes), under
    a random key, so the entry is not in the source at all: its row and
    the two actions that read it are added here, to the table wixl makes
    for every package;

    it has no element for a registry key to delete on uninstall;

    it records the time it ran as the package's creation time.

The package is not signed.
"""

from __future__ import annotations

import argparse
import calendar
import collections
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree

# make_zip from beside this file, without leaving a __pycache__ in the
# checkout it then finds changed.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_zip
from make_zip import Error

ICON = Path(__file__).resolve().parent / "ghostty.ico"

PRODUCT = "Ghostty"
MANUFACTURER = "Pyre909"
HOMEPAGE = "https://github.com/Pyre909/ghostty"
DESCRIPTION = "Ghostty for Windows, an unofficial build from the fork at " + HOMEPAGE

# How a package finds the installed Ghostty it replaces. It must never
# change, and it is the same for both architectures: they install to the
# same folder, so one has to replace the other.
UPGRADE_CODE = "35E4D04C-BBFB-4011-AAE3-B8C729AB8B7A"

# The namespace of every GUID derived here (`guid`). Changing it changes
# every component's GUID, which a component must keep.
NAMESPACE = uuid.UUID("4241E612-9EB3-4A6F-BC2E-B4700A596477")

# The key whose values are the components' key paths, one per folder.
KEY = rf"Software\{MANUFACTURER}\{PRODUCT}\Installed"

# What Ghostty registers for its notifications: `app_id` in
# src/apprt/windows/toast.zig, of a release build.
TOAST_KEY = r"Software\Classes\AppUserModelId\com.mitchellh.ghostty"

# Where the two actions that read the Environment table go in the install
# sequence: the numbers Windows Installer's documentation suggests, which
# are also where wixl puts them for a source with an Environment element.
ENVIRONMENT_ACTIONS = {
    "RemoveEnvironmentStrings": 3300,
    "WriteEnvironmentStrings": 5200,
}

# The summary's platform of each architecture.
PLATFORMS = {"x86_64": "x64", "aarch64": "Arm64"}

# The zip's folder: ghostty-<version>-windows-<arch>.
FOLDER = re.compile(r"ghostty-(?P<version>.+)-windows-(?P<arch>[a-z0-9_]+)", re.ASCII)

# What a package's version can hold in its three numbers.
VERSION_LIMITS = (255, 255, 65535)

# Names Windows keeps for devices, whatever their extension.
DEVICES = frozenset(
    ["con", "prn", "aux", "nul"]
    + [f"com{i}" for i in range(1, 10)]
    + [f"lpt{i}" for i in range(1, 10)]
)

# The files the package itself points at.
EXE = "bin/ghostty.exe"
REQUIRED = (EXE, "bin/ghostty.com", "README.txt", "LICENSE.txt")

WIX = "http://schemas.microsoft.com/wix/2006/wi"


@dataclass(frozen=True)
class App:
    """What an app zip holds."""

    name: str  # the zip's folder, and the package's name without .msi
    version: str
    arch: str
    # Every file by its path under the folder, with forward slashes.
    files: dict[str, zipfile.ZipInfo]

    def when(self) -> int:
        """The latest of the files' times, which a zip holds without a
        zone and make_zip.py writes in UTC."""
        return max(
            calendar.timegm((*i.date_time, 0, 0, 0)) for i in self.files.values()
        )

    def dirs(self) -> list[str]:
        """Every folder to install, "" for the top one, parents first."""
        out = {""}
        for f in self.files:
            parts = f.split("/")[:-1]
            out.update("/".join(parts[:i]) for i in range(1, len(parts) + 1))
        return sorted(out)


def bad_name(part: str) -> str | None:
    """Why Windows would not take `part` as a file's or a folder's name."""
    if not part or part in (".", ".."):
        return "is not a name"
    if any(c in '<>:"\\|?*' or ord(c) < 32 for c in part):
        return "has a character Windows does not allow"
    if part[-1] in ". ":
        return "ends with a dot or a space"
    if part.split(".")[0].rstrip(" ").lower() in DEVICES:
        return "is a device's name"
    return None


def read_app(zf: zipfile.ZipFile) -> App:
    """The app in a zip, or an Error for a zip make_zip.py would not have
    made or Windows could not hold."""
    infos = zf.infolist()
    if not infos:
        raise Error("the zip is empty")
    name = infos[0].filename.split("/")[0]
    m = FOLDER.fullmatch(name)
    if not m or not make_zip.SEMVER.fullmatch(m["version"]):
        raise Error(
            f"the zip's folder is {name!r}, not ghostty-<version>-windows-<arch>"
        )
    if m["arch"] not in PLATFORMS:
        raise Error(f"{m['arch']!r} is not one of {sorted(PLATFORMS)}")
    files: dict[str, zipfile.ZipInfo] = {}
    # Windows compares names without case, files' and folders' alike.
    seen: dict[str, str] = {}
    problems = []
    for info in infos:
        full = info.filename
        if info.is_dir() or not full.startswith(name + "/"):
            problems.append(f"{full!r} is not a file in {name}")
            continue
        rel = full[len(name) + 1 :]
        parts = rel.split("/")
        for part in parts:
            why = bad_name(part)
            if why:
                problems.append(f"{rel!r}: {part!r} {why}")
        for i in range(1, len(parts) + 1):
            path = "/".join(parts[:i])
            kind = "file" if i == len(parts) else "folder"
            was = seen.setdefault(path.lower(), f"{kind} {path}")
            if was != f"{kind} {path}":
                problems.append(f"{kind} {path} and {was} are one name on Windows")
        files[rel] = info
    problems += [f"{f} is missing" for f in REQUIRED if f not in files]
    if problems:
        problems = list(dict.fromkeys(problems))
        raise Error("the zip is not an app zip:\n  " + "\n  ".join(problems))
    return App(name, m["version"], m["arch"], files)


def product_version(version: str) -> str:
    """A package's version of a semantic one: its first three numbers."""
    m = make_zip.SEMVER.fullmatch(version)
    assert m
    numbers = [int(m[i]) for i in (1, 2, 3)]
    for n, limit in zip(numbers, VERSION_LIMITS):
        if n > limit:
            raise Error(
                f"{version}: a package's version holds at most "
                + ".".join(str(v) for v in VERSION_LIMITS)
            )
    return ".".join(str(n) for n in numbers)


def guid(*parts: str) -> str:
    """A GUID that depends only on `parts`."""
    return str(uuid.uuid5(NAMESPACE, "\n".join(parts))).upper()


def source(app: App, product_code: str) -> str:
    """The WiX source of `app`'s package. A file's source is its path
    under `tree`, beside the source, and the icon is beside it too."""
    dirs = app.dirs()
    dir_id = {d: f"dir{i}" for i, d in enumerate(dirs)}
    wix = ElementTree.Element("Wix", xmlns=WIX)
    product = ElementTree.SubElement(
        wix,
        "Product",
        Id=product_code,
        Name=PRODUCT,
        Language="1033",
        Version=product_version(app.version),
        Manufacturer=MANUFACTURER,
        UpgradeCode=UPGRADE_CODE,
    )
    sub = ElementTree.SubElement
    # Schema 500 is the first with Arm64 packages; perUser sets the
    # summary's bit for a package that needs no elevation and leaves
    # ALLUSERS unset.
    sub(
        product,
        "Package",
        InstallerVersion="500",
        Compressed="yes",
        InstallScope="perUser",
        Description=f"{DESCRIPTION} ({app.version}, {app.arch})",
    )
    sub(
        product,
        "MajorUpgrade",
        AllowSameVersionUpgrades="yes",
        DowngradeErrorMessage=f"A newer version of {PRODUCT} is already installed.",
    )
    sub(product, "MediaTemplate", EmbedCab="yes")
    sub(product, "Icon", Id="ghostty.ico", SourceFile="ghostty.ico")
    for key, value in (
        ("ARPPRODUCTICON", "ghostty.ico"),
        ("ARPCOMMENTS", DESCRIPTION),
        ("ARPURLINFOABOUT", HOMEPAGE),
        # One feature, so there is nothing to change.
        ("ARPNOMODIFY", "1"),
        # Without this, Windows Installer has the Restart Manager end the
        # programs that hold the files it replaces or removes, and where
        # it cannot ask (/qn, /passive) it asks nobody: such an upgrade
        # ended an open Ghostty that ran without the package's console
        # host. (With it, the one thing that kept Ghostty open was that
        # the Restart Manager does not end OpenConsole.exe unless told to
        # force it.) With this, the Restart Manager still finds those
        # programs, so that they can be named where there is a question,
        # and ends none. The installed package decides for its own
        # removal, an upgrade's too: the property is not passed on to it
        # by the package that replaces it.
        ("MSIRESTARTMANAGERCONTROL", "DisableShutdown"),
    ):
        sub(product, "Property", Id=key, Value=value)

    target = sub(product, "Directory", Id="TARGETDIR", Name="SourceDir")
    local = sub(target, "Directory", Id="LocalAppDataFolder")
    programs = sub(local, "Directory", Id="UserPrograms", Name="Programs")
    elements = {}
    components = []
    for d in dirs:
        parent = elements[d.rpartition("/")[0]] if d else programs
        elements[d] = sub(
            parent,
            "Directory",
            Id=dir_id[d],
            Name=d.rpartition("/")[2] if d else PRODUCT,
        )
        win = d.replace("/", "\\") or "."
        component = sub(
            elements[d], "Component", Id=f"cmp{dir_id[d][3:]}", Guid=guid("folder", win)
        )
        components.append(component)
        sub(
            component,
            "RegistryValue",
            Root="HKCU",
            Key=KEY,
            Name=win,
            Type="integer",
            Value="1",
            KeyPath="yes",
        )
        # Validation rule ICE64 wants this row for each folder a package
        # makes in a profile: a folder that was there before Windows
        # Installer came to it, as a roaming profile's is on a second
        # computer, is removed only when a row says so. On one computer
        # the folders went without these rows as well.
        # https://learn.microsoft.com/en-us/windows/win32/msi/ice64
        sub(component, "RemoveFolder", Id=f"rm{dir_id[d][3:]}", On="uninstall")
    for n, f in enumerate(sorted(app.files)):
        d, _, base = f.rpartition("/")
        sub(
            components[dirs.index(d)],
            "File",
            Id=f"file{n}",
            Name=base,
            Source=f"tree/{f}",
        )
    bin_dir = dir_id[EXE.rpartition("/")[0]]
    menu_dir = sub(target, "Directory", Id="ProgramMenuFolder")
    menu = sub(menu_dir, "Component", Id="cmpMenu", Guid=guid("start menu"))
    components.append(menu)
    sub(
        menu,
        "RegistryValue",
        Root="HKCU",
        Key=KEY,
        Name="Start menu",
        Type="integer",
        Value="1",
        KeyPath="yes",
    )
    # Not advertised, so it is a plain shortcut to the file and shows the
    # program's own icon. Ghostty starts its shell in the user's home
    # whatever folder it is started in, so none is set.
    sub(
        menu,
        "Shortcut",
        Id="StartMenu",
        Name=PRODUCT,
        Description="Terminal emulator",
        Target=f"[{bin_dir}]{EXE.rpartition('/')[2]}",
    )

    feature = sub(product, "Feature", Id="Main", Title=PRODUCT, Level="1")
    for component in components:
        sub(feature, "ComponentRef", Id=component.get("Id"))
    ElementTree.indent(wix)
    return ElementTree.tostring(wix, encoding="unicode", xml_declaration=True) + "\n"


def run(cmd: list[str], cwd: Path) -> str:
    # TZ: the cabinet records each file's time as local time.
    env = dict(os.environ, TZ="UTC")
    try:
        return subprocess.run(
            cmd, cwd=cwd, env=env, check=True, capture_output=True, encoding="utf-8"
        ).stdout
    except subprocess.CalledProcessError as e:
        raise Error(f"{shlex.join(cmd)} failed:\n{e.stdout}{e.stderr}") from None


def table(tools: dict[str, str], msi: Path, name: str) -> list[dict[str, str]]:
    """A table's rows, each by column name, as `msiinfo export` prints
    them: the columns, their types, the table and its keys, then a row a
    line, all tab-separated."""
    lines = run([tools["msiinfo"], "export", str(msi), name], msi.parent).split("\n")
    columns = lines[0].split("\t")
    return [
        dict(zip(columns, line.split("\t"), strict=True)) for line in lines[3:] if line
    ]


def summary(tools: dict[str, str], msi: Path) -> dict[str, str]:
    out = {}
    for line in run([tools["msiinfo"], "suminfo", str(msi)], msi.parent).splitlines():
        key, _, value = line.partition(": ")
        out[key] = value
    return out


def filetime(seconds: int) -> bytes:
    """A time as a summary holds it: 100 ns units since 1601."""
    return ((seconds + 11644473600) * 10_000_000).to_bytes(8, "little")


def set_times(msi: Path, started: int, when: int) -> None:
    """Replaces the time wixl ran, which it records as the summary's
    creation and last-saved times, with `when`, so that the package does
    not depend on when it was built. The two are found as what they are in
    the file, a property of type VT_FILETIME (64) holding a whole second
    since `started`, and anything but exactly two fails."""
    data = bytearray(msi.read_bytes())
    found = []
    for second in range(started - 1, int(time.time()) + 2):
        needle = (64).to_bytes(4, "little") + filetime(second)
        at = data.find(needle)
        while at != -1:
            found.append(at)
            at = data.find(needle, at + 1)
    if len(found) != 2:
        raise Error(
            f"found {len(found)} times in the package's summary to replace, not 2"
        )
    for at in found:
        data[at + 4 : at + 12] = filetime(when)
    msi.write_bytes(data)


def finish(
    tools: dict[str, str], msi: Path, app: App, package_code: str, started: int
) -> None:
    """Edits the package wixl compiled: see the module's notes on wixl."""

    def sql(statement: str) -> None:
        run([tools["msibuild"], str(msi), "-q", statement], msi.parent)

    # The PATH entry: "=" sets the variable, "-" removes the entry again
    # on uninstall, and "[~];" keeps the variable's value in front.
    bin_dir = f"dir{app.dirs().index(EXE.rpartition('/')[0])}"
    sql(
        "INSERT INTO `Environment` (`Environment`, `Name`, `Value`, `Component_`) "
        f"VALUES ('UserPath', '=-PATH', '[~];[{bin_dir}]', 'cmp{bin_dir[3:]}')"
    )
    for action, sequence in ENVIRONMENT_ACTIONS.items():
        sql(
            "INSERT INTO `InstallExecuteSequence` (`Action`, `Sequence`) "
            f"VALUES ('{action}', {sequence})"
        )
    # A name of "-" and no value: the key is deleted, with what is in it,
    # when the component is removed, and nothing is written when it is
    # installed.
    sql(
        "INSERT INTO `Registry` (`Registry`, `Root`, `Key`, `Name`, `Component_`) "
        f"VALUES ('regToast', 1, '{TOAST_KEY}', '-', 'cmp0')"
    )
    # msibuild -s sets the summary's subject, author, platform and
    # package code, and leaves the rest.
    was = summary(tools, msi)
    run(
        [
            tools["msibuild"],
            str(msi),
            "-s",
            was["Subject"],
            was["Author"],
            f"{PLATFORMS[app.arch]};1033",
            "{" + package_code + "}",
        ],
        msi.parent,
    )
    set_times(msi, started, app.when())


def check(
    tools: dict[str, str], msi: Path, app: App, product_code: str, package_code: str
) -> None:
    """Fails unless the package is what this script means to build, read
    back from the package itself: above all what `finish` changed, and
    what makes the install one for the current user. A folder, its
    component and a file are found by what the package's tables say of
    them, not by the ids `source` gave them."""
    problems = []

    def want(what: str, got: object, expected: object) -> None:
        if got != expected:
            problems.append(f"{what} is {got!r}, not {expected!r}")

    def long(name: str) -> str:
        # A name is "short|long" when it is not a short one.
        return name.rpartition("|")[2]

    info = summary(tools, msi)
    want("the platform", info.get("Template"), f"{PLATFORMS[app.arch]};1033")
    want("the schema", info.get("Version", "").split(" ")[0], "500")
    # Word count: 2 = compressed files, 8 = no elevation needed.
    want("the source type", info.get("Source", "").split(" ")[0], "10")
    # msiinfo prints local times, and `run` sets the zone to UTC.
    created = time.asctime(time.gmtime(app.when()))
    want("the creation time", info.get("Created"), created)
    want("the last-saved time", info.get("Last saved"), created)
    want(
        "the package code", info.get("Revision number (UUID)"), "{" + package_code + "}"
    )
    properties = {r["Property"]: r["Value"] for r in table(tools, msi, "Property")}
    want("ALLUSERS", properties.get("ALLUSERS"), None)
    want("ProductCode", properties.get("ProductCode"), "{" + product_code + "}")
    want("UpgradeCode", properties.get("UpgradeCode"), "{" + UPGRADE_CODE + "}")
    want(
        "ProductVersion", properties.get("ProductVersion"), product_version(app.version)
    )
    directories = {r["Directory"]: r for r in table(tools, msi, "Directory")}
    want(
        "where it installs",
        sorted(
            (r["Directory_Parent"], long(r["DefaultDir"]))
            for r in directories.values()
            if "UserPrograms" in (r["Directory"], r["Directory_Parent"])
        ),
        [("LocalAppDataFolder", "Programs"), ("UserPrograms", PRODUCT)],
    )
    # Each folder under the one it installs to, by its path under that
    # one ("" for itself), and the component that installs it.
    folders = {}
    for d in directories:
        parts, at = [], d
        while (
            at in directories and directories[at]["Directory_Parent"] != "UserPrograms"
        ):
            parts.append(long(directories[at]["DefaultDir"]))
            at = directories[at]["Directory_Parent"]
        if at in directories:
            folders["/".join(reversed(parts))] = d
    components = table(tools, msi, "Component")
    component_of = {r["Directory_"]: r["Component"] for r in components}
    bin_dir = folders.get(EXE.rpartition("/")[0])
    want(
        "the environment",
        [tuple(r.values()) for r in table(tools, msi, "Environment")],
        [("UserPath", "=-PATH", f"[~];[{bin_dir}]", component_of.get(bin_dir))],
    )
    sequence = {
        r["Action"]: int(r["Sequence"])
        for r in table(tools, msi, "InstallExecuteSequence")
    }
    for action, at in ENVIRONMENT_ACTIONS.items():
        want(f"{action}'s place", sequence.get(action), at)
    registry = table(tools, msi, "Registry")
    want("the registry roots", {r["Root"] for r in registry}, {"1"})
    want(
        "the notification key's row",
        [
            (r["Name"], r["Value"], r["Component_"])
            for r in registry
            if r["Key"] == TOAST_KEY
        ],
        [("-", "", component_of.get(folders.get("")))],
    )
    # Every file where the zip has it and of the size it has there: the
    # ones that are not, the package's first and then the zip's.
    path_of = {d: path for path, d in folders.items()}
    folder_of = {r["Component"]: path_of.get(r["Directory_"]) for r in components}
    got = collections.Counter(
        (
            f"{folder_of.get(r['Component_'])}/{long(r['FileName'])}".lstrip("/"),
            int(r["FileSize"]),
        )
        for r in table(tools, msi, "File")
    )
    expected = collections.Counter((f, i.file_size) for f, i in app.files.items())
    differ = sorted((got - expected).elements()) + sorted((expected - got).elements())
    if differ:
        problems.append(f"the package's files and the zip's differ in {differ!r}")
    if problems:
        raise Error("the package is not as meant:\n  " + "\n  ".join(problems))


def extract(zf: zipfile.ZipFile, app: App, tree: Path) -> None:
    """The app's files under `tree`, each with its time in the zip, which
    the cabinet records and the install gives the file."""
    for rel, info in app.files.items():
        dest = tree / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(zf.read(info))
        when = calendar.timegm((*info.date_time, 0, 0, 0))
        os.utime(dest, (when, when))


def make(args: argparse.Namespace) -> None:
    tools = {}
    for tool in ("wixl", "msibuild", "msiinfo"):
        found = shutil.which(tool)
        if found is None:
            raise Error(f"{tool} is not on PATH; it is part of msitools")
        tools[tool] = found
    zip_path = args.zip.resolve()
    if not zip_path.is_file():
        raise Error(f"{args.zip} is not a file")
    out = (args.out or zip_path.parent).resolve()
    out.mkdir(parents=True, exist_ok=True)
    with (
        zipfile.ZipFile(zip_path) as zf,
        tempfile.TemporaryDirectory(dir=out, prefix=".stage-") as tmp,
    ):
        stage = Path(tmp)
        app = read_app(zf)
        extract(zf, app, stage / "tree")
        machine = make_zip.pe_machine(stage / "tree" / EXE)
        if machine != make_zip.ARCHES[app.arch]:
            got = "not a PE file" if machine is None else f"{machine:#06x}"
            raise Error(f"{EXE} is {got}, not {app.arch}")
        shutil.copyfile(ICON, stage / "ghostty.ico")
        # Everything the package is made from, but the codes themselves.
        made_from = "\n".join(
            [
                make_zip.sha256(zip_path),
                make_zip.sha256(ICON),
                source(app, "00000000-0000-0000-0000-000000000000"),
            ]
        )
        digest = hashlib.sha256(made_from.encode("utf-8")).hexdigest()
        product_code = guid("product", digest)
        package_code = guid("package", digest)
        (stage / "ghostty.wxs").write_text(source(app, product_code), "utf-8")
        msi = stage / f"{app.name}.msi"
        started = int(time.time())
        run([tools["wixl"], "-a", "x64", "-o", msi.name, "ghostty.wxs"], stage)
        finish(tools, msi, app, package_code, started)
        check(tools, msi, app, product_code, package_code)
        dest = out / msi.name
        os.replace(msi, dest)
    print(f"{make_zip.sha256(dest)}  {dest.name}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Build Ghostty's Windows installer from an app zip."
    )
    parser.add_argument("zip", type=Path, help="an app zip that make_zip.py made")
    parser.add_argument("--out", type=Path, help="where to write (beside the zip)")
    try:
        make(parser.parse_args(argv))
    except Error as e:
        print(f"make_msi: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
