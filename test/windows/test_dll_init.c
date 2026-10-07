/*
 * Minimal reproducer for the ghostty-internal DLL CRT initialization issue.
 *
 * Before the fix (DllMain calling __vcrt_initialize / __acrt_initialize),
 * loading ghostty-internal.dll and calling any function that touches the C
 * runtime crashed with "access violation writing 0x0000000000000024" because
 * Zig's _DllMainCRTStartup does not initialize the MSVC C runtime for DLL
 * targets.
 *
 * This test loads the DLL and calls ghostty_info, which exercises the CRT
 * (string handling, memory). If it returns a version string without
 * crashing, the CRT is properly initialized.
 *
 * Built for MinGW it also checks both halves of what mingw's _CRT_INIT does
 * for the DLL (DllMain forwards to it):
 *
 * - The C++ global constructors. It initializes ghostty with
 *   ghostty_init_wtf16 and runs the terminal-stream benchmark over
 *   multi-byte UTF-8, which decodes through simdutf. Without the
 *   constructors simdutf's implementation pointer is null and the decode
 *   crashes with an access violation.
 * - The DLL's atexit table. It creates a surface on a window with a custom
 *   shader that paints it magenta and waits until the window shows it.
 *   Compiling the shader runs glslang and spirv-cross, whose function-local
 *   statics register destructors with atexit; if the table was never
 *   initialized, as with a DllMain that only walks __CTOR_LIST__, that
 *   corrupts the heap. Reading the color back also proves the shader was
 *   compiled and drawn, so the step cannot pass without reaching that code.
 *   The table itself runs at process exit, after the last line printed, so
 *   the exit status is part of the result.
 *
 * The surface step also checks that ghostty loaded d3dcompiler_47.dll from
 * System32 even with a copy of it beside this exe, which a bare LoadLibrary
 * would pick first.
 *
 * The MSVC DllMain does not run the constructors yet, so the MSVC build
 * stops after ghostty_info. The MinGW checks are chosen by the compiler that
 * builds this test, so build the test and the DLL for the same ABI.
 *
 * Build:  zig cc test_dll_init.c -o test_dll_init.exe -target native-native-msvc
 *         zig cc test_dll_init.c -o test_dll_init.exe -target native-native-gnu -luser32 -lgdi32
 * Run:    see README.md (cmd.exe or PowerShell); the exit status must be 0.
 *
 * Expected output (after fix):
 *   ghostty_info: <version string>
 * and for MinGW also:
 *   ghostty_init_wtf16: 0
 *   pinned: ok
 *   terminal-stream over UTF-8: ok
 *   d3dcompiler_47.dll from System32: ok
 *   custom shader on a surface: ok
 * and exit status 0.
 */

#include <stdio.h>
#include <windows.h>

#include "../../include/ghostty.h"

typedef ghostty_info_s (*ghostty_info_fn)(void);

#ifdef __MINGW32__
#include <wchar.h>

typedef int (*ghostty_init_wtf16_fn)(const wchar_t *, uintptr_t);
typedef bool (*ghostty_benchmark_cli_fn)(const char *, const char *);
typedef ghostty_config_t (*ghostty_config_new_fn)(void);
typedef void (*ghostty_config_load_file_fn)(ghostty_config_t, const char *);
typedef void (*ghostty_config_finalize_fn)(ghostty_config_t);
typedef uint32_t (*ghostty_config_diagnostics_count_fn)(ghostty_config_t);
typedef void (*ghostty_config_free_fn)(ghostty_config_t);
typedef ghostty_app_t (*ghostty_app_new_fn)(const ghostty_runtime_config_s *, ghostty_config_t);
typedef void (*ghostty_app_tick_fn)(ghostty_app_t);
typedef void (*ghostty_app_free_fn)(ghostty_app_t);
typedef ghostty_surface_config_s (*ghostty_surface_config_new_fn)(void);
typedef ghostty_surface_t (*ghostty_surface_new_fn)(ghostty_app_t, const ghostty_surface_config_s *);
typedef void (*ghostty_surface_set_size_fn)(ghostty_surface_t, uint32_t, uint32_t);
typedef void (*ghostty_surface_free_fn)(ghostty_surface_t);

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

/* 2-, 3- and 4-byte UTF-8 sequences, so the stream leaves its ASCII fast
 * path and decodes through simdutf. */
static const char utf8_data[] =
    "\xc3\xa9 \xc3\xbc \xc3\x9f\r\n"
    "\xe6\x97\xa5\xe6\x9c\xac\xe8\xaa\x9e\r\n"
    "\xf0\x9f\x99\x82 \xce\xa9\xe2\x89\x88\xc3\xa7\xe2\x88\x9a\r\n";

static const char shader_source[] =
    "void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n"
    "    fragColor = vec4(1.0, 0.0, 1.0, 1.0);\n"
    "}\n";

static FARPROC need(HMODULE dll, const char *name) {
    FARPROC proc = GetProcAddress(dll, name);
    if (!proc) fprintf(stderr, "GetProcAddress(%s) failed: %lu\n", name, GetLastError());
    return proc;
}

/* A temp file's path: wide for this test's own file calls, and UTF-8 for
 * ghostty, which reads narrow paths as UTF-8 (WTF-8), so an ANSI path with
 * non-ASCII characters would not reach it intact. A UTF-16 code unit takes
 * at most 3 bytes of UTF-8. */
typedef struct {
    wchar_t wide[MAX_PATH];
    char utf8[MAX_PATH * 3];
} temp_path;

/* Writes data to a new file in the temp directory and stores its path.
 * The files live there rather than in the working directory so that a
 * crash, which skips the cleanup, leaves nothing behind in the caller's
 * directory. */
static int write_temp_file(const char *data, size_t len, temp_path *path) {
    wchar_t dir[MAX_PATH];
    DWORD n = GetTempPathW(MAX_PATH, dir);
    if (n == 0 || n >= MAX_PATH || GetTempFileNameW(dir, L"gtd", 0, path->wide) == 0) {
        fprintf(stderr, "cannot create a temp file: %lu\n", GetLastError());
        return 1;
    }
    if (WideCharToMultiByte(CP_UTF8, 0, path->wide, -1, path->utf8, (int)sizeof(path->utf8), NULL, NULL) == 0) {
        fprintf(stderr, "cannot convert a temp path to UTF-8: %lu\n", GetLastError());
        DeleteFileW(path->wide);
        return 1;
    }
    FILE *f = _wfopen(path->wide, L"wb");
    if (!f) {
        fprintf(stderr, "cannot write %s\n", path->utf8);
        DeleteFileW(path->wide);
        return 1;
    }
    size_t written = fwrite(data, 1, len, f);
    if (fclose(f) != 0 || written != len) {
        fprintf(stderr, "cannot write %s\n", path->utf8);
        DeleteFileW(path->wide);
        return 1;
    }
    return 0;
}

static int check_utf8_decode(HMODULE dll) {
    ghostty_benchmark_cli_fn bench_fn =
        (ghostty_benchmark_cli_fn)need(dll, "ghostty_benchmark_cli");
    if (!bench_fn) return 1;

    temp_path path;
    if (write_temp_file(utf8_data, sizeof(utf8_data) - 1, &path) != 0) return 1;

    /* Quoted because the temp directory can contain spaces; the benchmark
     * splits its arguments like a Windows command line. */
    char args[sizeof(path.utf8) + 16];
    snprintf(args, sizeof(args), "--data=\"%s\"", path.utf8);
    bool ok = bench_fn("terminal-stream", args);
    DeleteFileW(path.wide);
    fprintf(stderr, "terminal-stream over UTF-8: %s\n", ok ? "ok" : "failed");
    return ok ? 0 : 1;
}

static bool action_cb(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    (void)app;
    (void)target;
    /* The renderer thread presents by itself; nothing else is needed. */
    return action.tag == GHOSTTY_ACTION_RENDER;
}

static void wakeup_cb(void *userdata) { (void)userdata; }

static ghostty_clipboard_read_result_e read_clipboard_cb(void *userdata, ghostty_clipboard_e clipboard, void *state, const char *const *mimes, size_t count, bool confirmed) {
    (void)userdata;
    (void)clipboard;
    (void)state;
    (void)mimes;
    (void)count;
    (void)confirmed;
    return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED;
}

static void confirm_read_clipboard_cb(void *userdata, const ghostty_clipboard_confirm_s *confirm, void *state, ghostty_clipboard_request_e request) {
    (void)userdata;
    (void)confirm;
    (void)state;
    (void)request;
}

static void write_clipboard_cb(void *userdata, ghostty_clipboard_e clipboard, const ghostty_clipboard_content_s *content, size_t count, bool confirm) {
    (void)userdata;
    (void)clipboard;
    (void)content;
    (void)count;
    (void)confirm;
}

static void close_surface_cb(void *userdata, bool process_alive) {
    (void)userdata;
    (void)process_alive;
}

static LRESULT CALLBACK window_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

/* Whether the pixel at the center of the window's client area is magenta,
 * read back through DWM so a flip-model swap chain's content is included. */
static bool center_is_magenta(HWND hwnd) {
    RECT window, client;
    if (!GetWindowRect(hwnd, &window) || !GetClientRect(hwnd, &client)) return false;
    POINT origin = {0, 0};
    if (!ClientToScreen(hwnd, &origin)) return false;
    int w = window.right - window.left;
    int h = window.bottom - window.top;
    int x = origin.x - window.left + client.right / 2;
    int y = origin.y - window.top + client.bottom / 2;
    if (w <= 0 || h <= 0 || x < 0 || x >= w || y < 0 || y >= h) return false;

    BITMAPINFO bmi = {0};
    bmi.bmiHeader.biSize = sizeof(bmi.bmiHeader);
    bmi.bmiHeader.biWidth = w;
    bmi.bmiHeader.biHeight = -h;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    bool magenta = false;
    void *bits = NULL;
    HDC screen = GetDC(NULL);
    HDC dc = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateDIBSection(screen, &bmi, DIB_RGB_COLORS, &bits, NULL, 0);
    if (dc && bitmap) {
        HGDIOBJ old = SelectObject(dc, bitmap);
        if (PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)) {
            GdiFlush();
            const unsigned char *px = (const unsigned char *)bits + ((size_t)y * w + x) * 4;
            /* BGRA */
            magenta = px[2] > 200 && px[1] < 50 && px[0] > 200;
        }
        SelectObject(dc, old);
    }
    if (bitmap) DeleteObject(bitmap);
    if (dc) DeleteDC(dc);
    ReleaseDC(NULL, screen);
    return magenta;
}

static const wchar_t compiler_name[] = L"d3dcompiler_47.dll";

/* Stores <System32>\d3dcompiler_47.dll in path, or returns false if the
 * system directory cannot be read or the path does not fit. */
static bool system_compiler_path(wchar_t path[MAX_PATH]) {
    UINT n = GetSystemDirectoryW(path, MAX_PATH);
    if (n == 0 || n + 1 + wcslen(compiler_name) >= MAX_PATH) return false;
    path[n] = L'\\';
    wcscpy(path + n + 1, compiler_name);
    return true;
}

/* Copies the system's own d3dcompiler_47.dll beside this exe and stores
 * the copy's path. A bare LoadLibrary searches the exe's directory before
 * System32, so a ghostty that stopped restricting that load to System32
 * would load this copy instead, which compiler_from_system32 catches. The
 * copy is the genuine DLL, so the run is otherwise unchanged. */
static int stage_compiler_copy(wchar_t copy[MAX_PATH]) {
    wchar_t system[MAX_PATH];
    if (!system_compiler_path(system)) {
        fprintf(stderr, "GetSystemDirectoryW failed: %lu\n", GetLastError());
        return 1;
    }

    DWORD m = GetModuleFileNameW(NULL, copy, MAX_PATH);
    wchar_t *slash = m > 0 && m < MAX_PATH ? wcsrchr(copy, L'\\') : NULL;
    if (!slash || (size_t)(slash + 1 - copy) + wcslen(compiler_name) >= MAX_PATH) {
        fprintf(stderr, "cannot find this exe's directory: %lu\n", GetLastError());
        copy[0] = 0;
        return 1;
    }
    wcscpy(slash + 1, compiler_name);
    if (!CopyFileW(system, copy, FALSE)) {
        fprintf(stderr, "cannot copy %ls beside the exe: %lu\n", system, GetLastError());
        copy[0] = 0;
        return 1;
    }
    return 0;
}

/* Whether the d3dcompiler_47.dll loaded in this process is System32's.
 * ghostty loads it while it creates the first surface. */
static bool compiler_from_system32(void) {
    HMODULE module;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, compiler_name, &module)) {
        fprintf(stderr, "d3dcompiler_47.dll is not loaded: %lu\n", GetLastError());
        return false;
    }
    wchar_t loaded[MAX_PATH], expected[MAX_PATH];
    DWORD n = GetModuleFileNameW(module, loaded, MAX_PATH);
    if (n == 0 || n >= MAX_PATH || !system_compiler_path(expected)) {
        fprintf(stderr, "cannot read the d3dcompiler_47.dll path: %lu\n", GetLastError());
        return false;
    }
    bool ok = CompareStringOrdinal(loaded, -1, expected, -1, TRUE) == CSTR_EQUAL;
    fprintf(stderr, "d3dcompiler_47.dll from System32: %s\n", ok ? "ok" : "no");
    if (!ok) fprintf(stderr, "it was loaded from %ls\n", loaded);
    return ok;
}

static int check_shader_compile(HMODULE dll) {
    ghostty_config_new_fn config_new = (ghostty_config_new_fn)need(dll, "ghostty_config_new");
    ghostty_config_load_file_fn config_load_file = (ghostty_config_load_file_fn)need(dll, "ghostty_config_load_file");
    ghostty_config_finalize_fn config_finalize = (ghostty_config_finalize_fn)need(dll, "ghostty_config_finalize");
    ghostty_config_diagnostics_count_fn config_diagnostics_count = (ghostty_config_diagnostics_count_fn)need(dll, "ghostty_config_diagnostics_count");
    ghostty_config_free_fn config_free = (ghostty_config_free_fn)need(dll, "ghostty_config_free");
    ghostty_app_new_fn app_new = (ghostty_app_new_fn)need(dll, "ghostty_app_new");
    ghostty_app_tick_fn app_tick = (ghostty_app_tick_fn)need(dll, "ghostty_app_tick");
    ghostty_app_free_fn app_free = (ghostty_app_free_fn)need(dll, "ghostty_app_free");
    ghostty_surface_config_new_fn surface_config_new = (ghostty_surface_config_new_fn)need(dll, "ghostty_surface_config_new");
    ghostty_surface_new_fn surface_new = (ghostty_surface_new_fn)need(dll, "ghostty_surface_new");
    ghostty_surface_set_size_fn surface_set_size = (ghostty_surface_set_size_fn)need(dll, "ghostty_surface_set_size");
    ghostty_surface_free_fn surface_free = (ghostty_surface_free_fn)need(dll, "ghostty_surface_free");
    if (!config_new || !config_load_file || !config_finalize || !config_diagnostics_count ||
        !config_free || !app_new || !app_tick || !app_free || !surface_config_new ||
        !surface_new || !surface_set_size || !surface_free)
        return 1;

    int rc = 1;
    temp_path shader_path = {0}, config_path = {0};
    wchar_t compiler_copy[MAX_PATH] = L"";
    char config_text[sizeof(shader_path.utf8) + 32];
    int len;
    ghostty_config_t config = NULL;
    ghostty_runtime_config_s runtime = {0};
    ghostty_app_t app = NULL;
    WNDCLASSW wc = {0};
    HWND hwnd = NULL;
    ghostty_surface_config_s surface_config;
    ghostty_surface_t surface = NULL;
    RECT client;
    bool shown = false;
    ULONGLONG deadline;

    if (write_temp_file(shader_source, sizeof(shader_source) - 1, &shader_path) != 0) goto done;
    len = snprintf(config_text, sizeof(config_text), "custom-shader = %s\n", shader_path.utf8);
    if (len < 0 || (size_t)len >= sizeof(config_text)) goto done;
    if (write_temp_file(config_text, (size_t)len, &config_path) != 0) goto done;
    if (stage_compiler_copy(compiler_copy) != 0) goto done;

    config = config_new();
    if (!config) goto done;
    config_load_file(config, config_path.utf8);
    config_finalize(config);
    if (config_diagnostics_count(config) != 0) {
        fprintf(stderr, "the custom-shader config has diagnostics\n");
        goto done;
    }

    runtime.wakeup_cb = wakeup_cb;
    runtime.action_cb = action_cb;
    runtime.read_clipboard_cb = read_clipboard_cb;
    runtime.confirm_read_clipboard_cb = confirm_read_clipboard_cb;
    runtime.write_clipboard_cb = write_clipboard_cb;
    runtime.close_surface_cb = close_surface_cb;
    app = app_new(&runtime, config);
    if (!app) {
        fprintf(stderr, "ghostty_app_new failed\n");
        goto done;
    }

    wc.lpfnWndProc = window_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"test_dll_init";
    RegisterClassW(&wc);
    hwnd = CreateWindowExW(0, wc.lpszClassName, L"test_dll_init", WS_OVERLAPPEDWINDOW,
                           CW_USEDEFAULT, CW_USEDEFAULT, 480, 320, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) {
        fprintf(stderr, "CreateWindowExW failed: %lu\n", GetLastError());
        goto done;
    }
    ShowWindow(hwnd, SW_SHOWNOACTIVATE);

    surface_config = surface_config_new();
    surface_config.platform_tag = GHOSTTY_PLATFORM_WINDOWS;
    surface_config.platform.windows.hwnd = hwnd;
    surface_config.scale_factor = 1.0;
    surface = surface_new(app, &surface_config);
    if (!surface) {
        fprintf(stderr, "ghostty_surface_new failed\n");
        goto done;
    }
    if (!compiler_from_system32()) goto done;
    GetClientRect(hwnd, &client);
    surface_set_size(surface, (uint32_t)client.right, (uint32_t)client.bottom);

    /* The renderer thread compiles the custom shader before its first
     * frame; give it a bounded time to put that frame on screen. */
    deadline = GetTickCount64() + 15000;
    while (!shown && GetTickCount64() < deadline) {
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        app_tick(app);
        shown = center_is_magenta(hwnd);
        if (!shown) Sleep(50);
    }
    fprintf(stderr, "custom shader on a surface: %s\n", shown ? "ok" : "not drawn");
    if (shown) rc = 0;

done:
    if (surface) surface_free(surface);
    if (hwnd) DestroyWindow(hwnd);
    if (app) app_free(app);
    if (config) config_free(config);
    if (config_path.wide[0]) DeleteFileW(config_path.wide);
    if (shader_path.wide[0]) DeleteFileW(shader_path.wide);
    /* Fails while the copy is loaded, which only a failed check allows. */
    if (compiler_copy[0]) DeleteFileW(compiler_copy);
    return rc;
}

/* The checks run on a thread with a 16 MiB stack reserve, which also owns
 * the test window, the way an embedding host has to call libghostty (see
 * ghostty_init_wtf16 in ghostty.h). zig cc gives this test's main thread
 * that much too, like ghostty.exe, but MSVC's link and GNU ld reserve 1-2
 * MiB, and a .NET host's main thread overflows in ghostty_init_wtf16. */
static DWORD WINAPI mingw_checks(LPVOID param) {
    HMODULE dll = (HMODULE)param;
    ghostty_init_wtf16_fn init_fn = (ghostty_init_wtf16_fn)need(dll, "ghostty_init_wtf16");
    if (!init_fn) return 1;

    const wchar_t *cmdline = GetCommandLineW();
    int rc = init_fn(cmdline, (uintptr_t)wcslen(cmdline));
    fprintf(stderr, "ghostty_init_wtf16: %d\n", rc);
    if (rc != 0) return 1;

    /* A successful ghostty_init_wtf16 pins the DLL (see ghostty.h). Drop
     * this test's only reference and check, before calling into the DLL
     * again, that it is still mapped: unpinned, its count would reach zero
     * here and it would unmap under its own threads. The checks below then
     * run through the same pointers. */
    FreeLibrary(dll);
    bool pinned = GetModuleHandleW(L"ghostty-internal.dll") != NULL;
    fprintf(stderr, "pinned: %s\n", pinned ? "ok" : "FAILED");
    if (!pinned) return 1;

    if (check_utf8_decode(dll) != 0) return 1;
    return (DWORD)check_shader_compile(dll);
}

static int check_mingw_crt_init(HMODULE dll) {
    HANDLE thread = CreateThread(NULL, 16 * 1024 * 1024, mingw_checks, dll,
                                 STACK_SIZE_PARAM_IS_A_RESERVATION, NULL);
    if (!thread) {
        fprintf(stderr, "CreateThread failed: %lu\n", GetLastError());
        return 1;
    }
    DWORD exit_code = 1;
    WaitForSingleObject(thread, INFINITE);
    GetExitCodeThread(thread, &exit_code);
    CloseHandle(thread);
    return exit_code == 0 ? 0 : 1;
}
#endif

int main(void) {
    HMODULE dll = LoadLibraryA("ghostty-internal.dll");
    if (!dll) {
        fprintf(stderr, "LoadLibrary failed: %lu\n", GetLastError());
        return 1;
    }

    ghostty_info_fn info_fn = (ghostty_info_fn)GetProcAddress(dll, "ghostty_info");
    if (!info_fn) {
        fprintf(stderr, "GetProcAddress(ghostty_info) failed: %lu\n", GetLastError());
        return 1;
    }

    ghostty_info_s info = info_fn();
    fprintf(stderr, "ghostty_info: %.*s\n", (int)info.version_len, info.version);

#ifdef __MINGW32__
    if (check_mingw_crt_init(dll) != 0) return 1;
#endif

    /* Beyond the pin check, which frees the MinGW build's reference to
     * show it has no effect, this test does not unload the DLL: ghostty's
     * global state has no teardown. On MinGW the DLL's atexit table, which
     * the shader step fills, still runs at process exit (DLL_PROCESS_DETACH
     * reaches _CRT_INIT), after the last line printed here, so the exit
     * status is part of the result. */
    return 0;
}
