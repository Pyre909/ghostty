Ghostty for Windows, portable zip

Unzip anywhere and run bin\ghostty.exe. Nothing is installed.
LICENSE.txt is Ghostty's license; THIRD-PARTY-NOTICES.txt lists the
other software in this zip and its licenses.


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
into the same place as this one, so that each .pdb file sits beside its
program, and open the dump in WinDbg.

Some crashes end the process before Ghostty can write anything, such as
a fast fail when Windows finds the heap or the stack corrupted. Windows
Error Reporting can dump those. From an administrator command prompt:

    reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\ghostty.exe" /f

Windows then writes a minidump of any ghostty.exe crash, keeping 10,
in %LOCALAPPDATA%\CrashDumps. Add /v DumpType /t REG_DWORD /d 2 to that
command for full dumps. See "Collecting User-Mode Dumps" in Microsoft's
documentation for the other settings. To turn it off again:

    reg delete "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\ghostty.exe" /f
