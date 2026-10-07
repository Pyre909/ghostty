# Windows Tests

Manual test programs for Windows-specific functionality.

## test_dll_init.c

Regression test for the DLL CRT initialization fix. Loads
ghostty-internal.dll at runtime and calls ghostty_info to verify the C
runtime is properly initialized.

Built for MinGW it also checks both halves of what mingw's `_CRT_INIT`
does for the DLL, which its DllMain forwards to:

- The C++ global constructors: it calls ghostty_init_wtf16 and runs the
  terminal-stream benchmark over multi-byte UTF-8, which decodes through
  simdutf. A DllMain that runs no constructors crashes here with an access
  violation.
- The DLL's atexit table: it opens a small window, creates a surface on it
  with a custom shader that paints the surface magenta, and waits up to 15
  seconds until it reads magenta back from the window. Compiling the
  shader runs glslang and spirv-cross, whose function-local statics
  register destructors with atexit. A DllMain that only walks
  `__CTOR_LIST__` passes the first check and corrupts the heap here. The
  table itself runs at process exit, after the last printed line, so only
  the exit status shows that it ran cleanly.

The surface step also copies the system's own d3dcompiler_47.dll beside
the test exe and checks that ghostty still loaded System32's: a bare
LoadLibrary would pick the copy first. It deletes the copy afterwards.
The copy stays if the run crashes or the check fails, because ghostty then
still has it loaded; the next run overwrites it.

The window appears briefly while the test runs. The checks run on a
thread with a 16 MiB stack, as an embedding host must call libghostty
(see ghostty_init_wtf16 in ghostty.h). The MinGW checks are compiled in
when the test itself is built for MinGW, so build the test and the DLL for
the same ABI. Set `GHOSTTY_LOG=stderr` to see ghostty's own log lines,
including the custom shader being loaded and compiled.

### Build

First build ghostty-internal.dll, then compile the test:

```
zig build -Dapp-runtime=none -Demit-exe=false
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
```

For MinGW, build both for the GNU ABI. This is the build an embedding
host needs: an MSVC-built DLL does not run its C++ initialization yet, so
its ghostty_init_wtf16 always fails.

```
zig build -Dapp-runtime=none -Demit-exe=false -Dtarget=native-windows-gnu
zig cc test_dll_init.c -o test_dll_init.exe -target native-native-gnu -luser32 -lgdi32
```

Rebuild the DLL whenever you switch ABI: the run copies whatever
ghostty-internal.dll is in zig-out\lib.

### Run

From this directory, in cmd.exe:

```
copy ..\..\zig-out\lib\ghostty-internal.dll .
test_dll_init.exe
echo exit=%ERRORLEVEL%
```

or in PowerShell:

```
Copy-Item ..\..\zig-out\lib\ghostty-internal.dll .
.\test_dll_init.exe
"exit=$LASTEXITCODE"
```

Expected output (after the CRT fix):

```
ghostty_info: <version string>
```

and for MinGW also:

```
ghostty_init_wtf16: 0
pinned: ok
terminal-stream over UTF-8: ok
d3dcompiler_47.dll from System32: ok
custom shader on a surface: ok
```

and in both cases `exit=0`.

The ghostty_info call verifies the DLL loads and the CRT is initialized.
Before the fix, loading the DLL would crash with "access violation writing
0x0000000000000024".
