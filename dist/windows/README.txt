Ghostty for Windows, unofficial build

This is a build of the fork at https://github.com/Pyre909/ghostty. The
Ghostty project did not make, review or sign it. LICENSE.txt is
Ghostty's license; THIRD-PARTY-NOTICES.txt lists the other software in
this package and its licenses.

It comes as a zip and as an installer, which hold the same files.


Portable zip
------------

Unzip anywhere and run bin\ghostty.exe. Nothing is installed.


Installer
---------

The .msi installs Ghostty for the current user only, in

    %LOCALAPPDATA%\Programs\Ghostty

and needs no administrator rights. It adds Ghostty to the Start menu
and the bin folder to the user's PATH, which command prompts opened
afterwards see. It is not signed, so Windows may warn that its
publisher is unknown.

A newer installer replaces the installed version, and an older one is
refused. Remove Ghostty under Settings > Apps > Installed apps. That
leaves what Ghostty wrote in %LOCALAPPDATA%\ghostty: the configuration
and the crash dumps.

The installer never closes Ghostty. Where it can ask, as after a
double click, and Ghostty is open, it names Ghostty and asks for it to
be closed first: close Ghostty, then choose Retry. Where it does not
ask (msiexec /qn or /passive, and the x64 build on Arm64 Windows), it
installs or removes around the open Ghostty, which goes on as the
version it was until it is closed.


Crash dumps
-----------

When Ghostty crashes, it writes a minidump before it ends, to

    %LOCALAPPDATA%\ghostty\crash

or to ghostty\crash under XDG_STATE_HOME when that variable is set. The
files are named ghostty-<date>-<time>-<process id>.dmp, in UTC, and
Ghostty keeps the newest 10 when it starts. In a command prompt,
bin\ghostty +crash-report lists them.

A minidump holds the threads' stacks, the loaded modules and the open
handles, not the heap, where the screen and the scrollback are kept
(a stack can still hold a little of the text being worked on). Its
comment names Ghostty's version, the thread that crashed and, for a
panic, the panic's message. To write full dumps instead, which hold all
of the process's memory and so whatever was on screen, set
GHOSTTY_CRASH_DUMP=full before starting Ghostty.

To read a dump with symbols, unzip the -pdb zip of the same version
into the same place as the zip, so that each .pdb file sits beside its
program (for an installed Ghostty, copy them into its bin folder), and
open the dump in WinDbg.

Some crashes end the process before Ghostty can write anything, such as
a fast fail when Windows finds the heap or the stack corrupted. Windows
Error Reporting can dump those, with a setting that is for the whole
machine: while the registry key LocalDumps exists, Windows writes a
minidump of every program that crashes, not only of Ghostty, and keeps
the newest 10 in the user's %LOCALAPPDATA%\CrashDumps unless the key
sets another folder or count. See first whether the machine has the
key, which another program's installer may have made:

    reg query "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps"

If it has, crashes are dumped already. If the command reports an error
instead, this makes the key, from an administrator command prompt:

    reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\ghostty.exe" /f

The ghostty.exe key under LocalDumps holds settings for Ghostty alone:
add /v DumpType /t REG_DWORD /d 2 to that command for full dumps of
Ghostty. See "Collecting User-Mode Dumps" in Microsoft's documentation
for the other settings.

To turn it off again, delete what was added. On a machine that had no
LocalDumps key, that is the whole key:

    reg delete "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps" /f

On a machine that had one, leave it and delete only Ghostty's key:

    reg delete "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\ghostty.exe" /f
