const std = @import("std");
const windows = std.os.windows;

// NOTE: The Windows part of the Zig stdlib is currently in the process of
// having most of its features removed, with the ultimate goal of switching to
// serve as a support for higher-level functionality offered in places like
// `std.Io` only. As such this file serves as a "bridge" between type
// information (mostly coming from stdlib) and manually-defined constants and
// external functions.

// Utility functions
pub const GetCurrentProcessId = windows.GetCurrentProcessId;
pub const GetLastError = windows.GetLastError;
pub const unexpectedError = windows.unexpectedError;
pub const unexpectedStatus = windows.unexpectedStatus;

// Primitive types
pub const BOOL = windows.BOOL;
pub const COORD = windows.COORD;
pub const DWORD = windows.DWORD;
pub const DWORD_PTR = windows.DWORD_PTR;
pub const HANDLE = windows.HANDLE;
pub const HINSTANCE = windows.HINSTANCE;
pub const HMODULE = windows.HMODULE;
pub const HWND = windows.HWND;
pub const HPCON = windows.LPVOID;
pub const HRESULT = c_long;
pub const LARGE_INTEGER = windows.LARGE_INTEGER;
pub const LONG = windows.LONG;
pub const LPCVOID = windows.LPCVOID;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPSTR = windows.LPSTR;
pub const LPVOID = windows.LPVOID;
pub const LPWSTR = windows.LPWSTR;
pub const PVOID = windows.PVOID;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const ULONG = windows.ULONG;
pub const ULONG_PTR = windows.ULONG_PTR;
pub const UNICODE_STRING = windows.UNICODE_STRING;

// Structs and opaque types
pub const LPPROC_THREAD_ATTRIBUTE_LIST = ?*anyopaque;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTF_USESTDHANDLES = windows.STARTF_USESTDHANDLES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

/// https://learn.microsoft.com/en-us/windows/win32/api/windef/ns-windef-rect
pub const RECT = extern struct {
    left: LONG,
    top: LONG,
    right: LONG,
    bottom: LONG,
};

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};
pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};
pub const STARTUPINFOEX = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
};

// Well-known constant values
pub const INFINITE = 4294967295;
pub const INVALID_HANDLE_VALUE = windows.INVALID_HANDLE_VALUE;
pub const MAX_PATH = windows.MAX_PATH;
pub const FALSE: windows.BOOL = .fromBool(false);
pub const TRUE: windows.BOOL = .fromBool(true);

// Bit-field and enum constant values
/// AttachConsole dwProcessId: the console of the process that started us.
pub const ATTACH_PARENT_PROCESS: DWORD = 0xFFFFFFFF;
pub const CP_UTF8 = 65001;
pub const CREATE_UNICODE_ENVIRONMENT = 0x00000400;
pub const CTRL_BREAK_EVENT = 1;
pub const CTRL_C_EVENT = 0;
pub const DELETE = 0x00010000;
pub const DUPLICATE_SAME_ACCESS = windows.DUPLICATE_SAME_ACCESS;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING = windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
pub const ERROR_SUCCESS = 0;
pub const EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
pub const FILE_ATTRIBUTE_NORMAL = 0x80;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE = 0x00080000;
pub const FILE_FLAG_OVERLAPPED = 0x40000000;
/// GetFinalPathNameByHandleW dwFlags: normalized name with a DOS drive
/// letter (both are the zero flag values).
pub const FILE_NAME_NORMALIZED = 0x0;
pub const FILE_NON_DIRECTORY_FILE = 0x00000040;
/// NtCreateFile CreateDisposition: open an existing file, never create.
/// Distinct from the Win32 CreateFileW value OPEN_EXISTING.
pub const FILE_OPEN = 0x00000001;
pub const FILE_OPEN_REPARSE_POINT = 0x00200000;
pub const FILE_SHARE_DELETE = 0x00000004;
pub const FILE_SHARE_READ = 0x00000001;
pub const FILE_SHARE_WRITE = 0x00000002;
pub const FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
pub const GENERIC_READ = 0x80000000;
/// GetModuleHandleExW dwFlags: lpModuleName is an address inside the
/// module rather than its name.
pub const GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS = 0x00000004;
/// GetModuleHandleExW dwFlags: keep the module loaded until the process
/// ends, whatever FreeLibrary calls follow.
pub const GET_MODULE_HANDLE_EX_FLAG_PIN = 0x00000001;
pub const HANDLE_FLAG_INHERIT = 0x00000001;
/// LoadLibraryExW dwFlags: search the folder of the DLL being loaded, which
/// must be named by its full path, for the DLLs it imports.
pub const LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR = 0x00000100;
/// LoadLibraryExW dwFlags: search only %windows%\system32 for the DLL and
/// its dependencies, never the standard search path.
pub const LOAD_LIBRARY_SEARCH_SYSTEM32 = 0x00000800;
pub const MEM_COMMIT = 0x1000;
pub const MEM_RELEASE = 0x8000;
pub const MEM_RESERVE = 0x2000;
pub const OPEN_EXISTING = 3; // Known as FILE_OPEN in Windows docs
pub const PAGE_READWRITE = 0x04;
pub const PIPE_ACCESS_OUTBOUND = 0x00000002;
pub const PIPE_TYPE_BYTE = 0x00000000;
pub const PROC_THREAD_ATTRIBUTE_ADDITIVE = 0x00040000;
pub const PROC_THREAD_ATTRIBUTE_INPUT = 0x00020000;
pub const PROC_THREAD_ATTRIBUTE_NUMBER = 0x0000FFFF;
pub const PROC_THREAD_ATTRIBUTE_THREAD = 0x00010000;
/// CreatePseudoConsole dwFlags, as Microsoft's ConPTY package
/// (Microsoft.Windows.Console.ConPTY) names them in its conpty.h: how the
/// console host measures text, a grapheme cluster as one character or
/// each codepoint by its wcwidth.
pub const PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES = 0x08;
pub const PSEUDOCONSOLE_GLYPH_WIDTH_WCSWIDTH = 0x10;
pub const S_OK = 0;
/// GetStdHandle/SetStdHandle nStdHandle values ((DWORD)-12, -10, -11).
pub const STD_ERROR_HANDLE: DWORD = 0xFFFFFFF4;
pub const STD_INPUT_HANDLE: DWORD = 0xFFFFFFF6;
pub const STD_OUTPUT_HANDLE: DWORD = 0xFFFFFFF5;
pub const SYNCHRONIZE = 0x00100000;
pub const VOLUME_NAME_DOS = 0x0;
pub const WAIT_FAILED = 0xFFFFFFFF;
pub const WAIT_OBJECT_0 = 0x00000000;
pub const WAIT_TIMEOUT = 0x00000102;

/// IOCTL that fills the output buffer with bytes from the kernel CSPRNG
/// behind `\Device\CNG` (what ProcessPrng and BCryptGenRandom draw from).
pub const IOCTL_KSEC_GEN_RANDOM: CTL_CODE = windows.IOCTL.KSEC.GEN_RANDOM;

pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = ProcThreadAttributeValue(
    .ProcThreadAttributePseudoConsole,
    false,
    true,
    false,
);

// Types needed for ntdll calls
pub const ACCESS_MASK = windows.ACCESS_MASK;
pub const CTL_CODE = windows.CTL_CODE;
pub const FILE_ALL_INFORMATION = windows.FILE.ALL_INFORMATION;
pub const FILE_ATTRIBUTE_TAG_INFORMATION = windows.FILE.ATTRIBUTE_TAG_INFO;
pub const FILE_DISPOSITION_INFORMATION = windows.FILE.DISPOSITION.INFORMATION;
pub const FILE_DISPOSITION_INFORMATION_EX = windows.FILE.DISPOSITION.INFORMATION.EX;
pub const FILE_INFORMATION_CLASS = windows.FILE.INFORMATION_CLASS;
pub const FILE_POSITION_INFORMATION = windows.FILE.POSITION_INFORMATION;
pub const FILE_STANDARD_INFORMATION = windows.FILE.STANDARD_INFORMATION;
pub const IO_STATUS_BLOCK = windows.IO_STATUS_BLOCK;
pub const NTSTATUS = windows.NTSTATUS;
pub const OBJECT_ATTRIBUTES = windows.OBJECT.ATTRIBUTES;

/// https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/ne-sysinfoapi-computer_name_format
pub const COMPUTER_NAME_FORMAT = enum(c_int) {
    NetBIOS = 0,
    DnsHostname = 1,
    DnsDomain = 2,
    DnsFullyQualified = 3,
    PhysicalNetBIOS = 4,
    PhysicalDnsHostname = 5,
    PhysicalDnsDomain = 6,
    PhysicalDnsFullyQualified = 7,
};

// Exported functions by library
pub const exp = struct {
    pub const kernel32 = struct {
        pub extern "kernel32" fn CreatePipe(
            hReadPipe: *HANDLE,
            hWritePipe: *HANDLE,
            lpPipeAttributes: ?*const SECURITY_ATTRIBUTES,
            nSize: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreatePseudoConsole(
            size: COORD,
            hInput: HANDLE,
            hOutput: HANDLE,
            dwFlags: DWORD,
            phPC: *HPCON,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ResizePseudoConsole(
            hPC: HPCON,
            size: COORD,
        ) callconv(.winapi) HRESULT;
        pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;
        pub extern "kernel32" fn InitializeProcThreadAttributeList(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwAttributeCount: DWORD,
            dwFlags: DWORD,
            lpSize: *SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn UpdateProcThreadAttribute(
            lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
            dwFlags: DWORD,
            Attribute: DWORD_PTR,
            lpValue: PVOID,
            cbSize: SIZE_T,
            lpPreviousValue: ?PVOID,
            lpReturnSize: ?*SIZE_T,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn PeekNamedPipe(
            hNamedPipe: HANDLE,
            lpBuffer: ?LPVOID,
            nBufferSize: DWORD,
            lpBytesRead: ?*DWORD,
            lpTotalBytesAvail: ?*DWORD,
            lpBytesLeftThisMessage: ?*DWORD,
        ) callconv(.winapi) BOOL;
        // Duplicated here because lpCommandLine is not marked optional in zig std
        pub extern "kernel32" fn CreateProcessW(
            lpApplicationName: ?LPWSTR,
            lpCommandLine: ?LPWSTR,
            lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
            lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
            bInheritHandles: BOOL,
            dwCreationFlags: DWORD,
            lpEnvironment: ?*anyopaque,
            lpCurrentDirectory: ?LPWSTR,
            lpStartupInfo: *STARTUPINFOW,
            lpProcessInformation: *PROCESS_INFORMATION,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getcomputernamea
        pub extern "kernel32" fn GetComputerNameA(
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getcomputernameexa
        pub extern "kernel32" fn GetComputerNameExA(
            NameType: COMPUTER_NAME_FORMAT,
            lpBuffer: LPSTR,
            nSize: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-gettemppathw
        pub extern "kernel32" fn GetTempPathW(
            nBufferLength: DWORD,
            lpBuffer: LPWSTR,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn SetHandleInformation(
            hObject: HANDLE,
            dwMask: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CreateFileW(
            lpFileName: LPCWSTR,
            dwDesiredAccess: DWORD,
            dwShareMode: DWORD,
            lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
            dwCreationDisposition: DWORD,
            dwFlagsAndAttributes: DWORD,
            hTemplateFile: ?HANDLE,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CreateNamedPipeW(
            lpName: LPCWSTR,
            dwOpenMode: DWORD,
            dwPipeMode: DWORD,
            nMaxInstances: DWORD,
            nOutBufferSize: DWORD,
            nInBufferSize: DWORD,
            nDefaultTimeOut: DWORD,
            lpSecurityAttributes: ?*const SECURITY_ATTRIBUTES,
        ) callconv(.winapi) HANDLE;
        pub extern "kernel32" fn CloseHandle(
            hObject: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn VirtualAlloc(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            flAllocationType: DWORD,
            flProtect: DWORD,
        ) callconv(.winapi) ?LPVOID;
        pub extern "kernel32" fn VirtualFree(
            lpAddress: ?LPVOID,
            dwSize: SIZE_T,
            dwFreeType: DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/memoryapi/nf-memoryapi-discardvirtualmemory
        pub extern "kernel32" fn DiscardVirtualMemory(
            VirtualAddress: PVOID,
            Size: SIZE_T,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn WaitForSingleObject(
            hHandle: HANDLE,
            dwMilliseconds: DWORD,
        ) callconv(.winapi) DWORD;
        pub extern "kernel32" fn GetExitCodeProcess(
            hProcess: HANDLE,
            lpExitCode: *DWORD,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn TerminateProcess(
            hProcess: HANDLE,
            uExitCode: UINT,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn CancelIoEx(
            hFile: HANDLE,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// Cancels pending *synchronous* I/O issued by `hThread` (the
        /// thread handle needs THREAD_TERMINATE access). Fails with
        /// ERROR_NOT_FOUND when that thread has no I/O in progress.
        /// https://learn.microsoft.com/en-us/windows/win32/fileio/cancelsynchronousio-func
        pub extern "kernel32" fn CancelSynchronousIo(
            hThread: HANDLE,
        ) callconv(.winapi) BOOL;
        pub extern "kernel32" fn ReadFile(
            hFile: HANDLE,
            lpBuffer: LPVOID,
            nNumberOfBytesToRead: DWORD,
            lpNumberOfBytesRead: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-writefile
        pub extern "kernel32" fn WriteFile(
            hFile: HANDLE,
            lpBuffer: LPCVOID,
            nNumberOfBytesToWrite: DWORD,
            lpNumberOfBytesWritten: ?*DWORD,
            lpOverlapped: ?*OVERLAPPED,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfinalpathnamebyhandlew
        pub extern "kernel32" fn GetFinalPathNameByHandleW(
            hFile: HANDLE,
            lpszFilePath: [*]u16,
            cchFilePath: DWORD,
            dwFlags: DWORD,
        ) callconv(.winapi) DWORD;
        /// https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandlew
        pub extern "kernel32" fn GetModuleHandleW(
            lpModuleName: ?LPCWSTR,
        ) callconv(.winapi) ?HMODULE;
        /// https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandleexw
        pub extern "kernel32" fn GetModuleHandleExW(
            dwFlags: DWORD,
            lpModuleName: ?LPCWSTR,
            phModule: *?HMODULE,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-loadlibraryexw
        pub extern "kernel32" fn LoadLibraryExW(
            lpLibFileName: LPCWSTR,
            hFile: ?HANDLE,
            dwFlags: DWORD,
        ) callconv(.winapi) ?HMODULE;
        /// https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getprocaddress
        pub extern "kernel32" fn GetProcAddress(
            hModule: HMODULE,
            lpProcName: [*:0]const u8,
        ) callconv(.winapi) ?*const anyopaque;
        /// https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-freelibrary
        pub extern "kernel32" fn FreeLibrary(hLibModule: HMODULE) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/console/attachconsole
        pub extern "kernel32" fn AttachConsole(
            dwProcessId: DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/console/getstdhandle
        pub extern "kernel32" fn GetStdHandle(
            nStdHandle: DWORD,
        ) callconv(.winapi) ?HANDLE;
        /// https://learn.microsoft.com/en-us/windows/console/setconsolectrlhandler
        pub extern "kernel32" fn SetConsoleCtrlHandler(
            HandlerRoutine: ?*const fn (dwCtrlType: DWORD) callconv(.winapi) BOOL,
            Add: BOOL,
        ) callconv(.winapi) BOOL;
        /// Fails for a handle that is not a console's.
        /// https://learn.microsoft.com/en-us/windows/console/getconsolemode
        pub extern "kernel32" fn GetConsoleMode(
            hConsoleHandle: HANDLE,
            lpMode: *DWORD,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/console/setconsolemode
        pub extern "kernel32" fn SetConsoleMode(
            hConsoleHandle: HANDLE,
            dwMode: DWORD,
        ) callconv(.winapi) BOOL;
        /// Returns 0 when the process has no console.
        /// https://learn.microsoft.com/en-us/windows/console/getconsoleoutputcp
        pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) UINT;
        /// https://learn.microsoft.com/en-us/windows/console/setconsoleoutputcp
        pub extern "kernel32" fn SetConsoleOutputCP(
            wCodePageID: UINT,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/console/writeconsole
        pub extern "kernel32" fn WriteConsoleW(
            hConsoleOutput: HANDLE,
            lpBuffer: [*]const u16,
            nNumberOfCharsToWrite: DWORD,
            lpNumberOfCharsWritten: ?*DWORD,
            lpReserved: ?*anyopaque,
        ) callconv(.winapi) BOOL;
        /// Returns the value's length, the size it needs (with its NUL) when
        /// the buffer is too small, or 0 when it is not set or empty.
        /// https://learn.microsoft.com/en-us/windows/win32/api/processenv/nf-processenv-getenvironmentvariablew
        pub extern "kernel32" fn GetEnvironmentVariableW(
            lpName: LPCWSTR,
            lpBuffer: ?[*]u16,
            nSize: DWORD,
        ) callconv(.winapi) DWORD;
        /// https://learn.microsoft.com/en-us/windows/win32/api/processenv/nf-processenv-setenvironmentvariablew
        pub extern "kernel32" fn SetEnvironmentVariableW(
            lpName: LPCWSTR,
            lpValue: ?LPCWSTR,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getstartupinfow
        pub extern "kernel32" fn GetStartupInfoW(
            lpStartupInfo: *STARTUPINFOW,
        ) callconv(.winapi) void;
        /// https://learn.microsoft.com/en-us/windows/win32/api/handleapi/nf-handleapi-duplicatehandle
        pub extern "kernel32" fn DuplicateHandle(
            hSourceProcessHandle: HANDLE,
            hSourceHandle: HANDLE,
            hTargetProcessHandle: HANDLE,
            lpTargetHandle: *HANDLE,
            dwDesiredAccess: DWORD,
            bInheritHandle: BOOL,
            dwOptions: DWORD,
        ) callconv(.winapi) BOOL;
    };
    pub const user32 = struct {
        /// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getclientrect
        pub extern "user32" fn GetClientRect(
            hWnd: HWND,
            lpRect: *RECT,
        ) callconv(.winapi) BOOL;
        /// https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getdoubleclicktime
        pub extern "user32" fn GetDoubleClickTime() callconv(.winapi) UINT;
    };
    pub const ntdll = struct {
        pub extern "ntdll" fn NtCreateFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            AllocationSize: ?*LARGE_INTEGER,
            FileAttributes: ULONG,
            ShareAccess: ULONG,
            CreateDisposition: ULONG,
            CreateOptions: ULONG,
            EaBuffer: ?*anyopaque,
            EaLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtOpenFile(
            FileHandle: *HANDLE,
            DesiredAccess: ACCESS_MASK,
            ObjectAttributes: *OBJECT_ATTRIBUTES,
            IoStatusBlock: *IO_STATUS_BLOCK,
            ShareAccess: ULONG,
            OpenOptions: ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtClose(Handle: HANDLE) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtReadFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            Buffer: *anyopaque,
            Length: ULONG,
            ByteOffset: ?*const LARGE_INTEGER,
            Key: ?*const ULONG,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtQueryInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtSetInformationFile(
            FileHandle: HANDLE,
            IoStatusBlock: *IO_STATUS_BLOCK,
            FileInformation: *anyopaque,
            Length: ULONG,
            FileInformationClass: FILE_INFORMATION_CLASS,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn NtDeviceIoControlFile(
            FileHandle: HANDLE,
            Event: ?HANDLE,
            ApcRoutine: ?*const anyopaque,
            ApcContext: ?*anyopaque,
            IoStatusBlock: *IO_STATUS_BLOCK,
            IoControlCode: CTL_CODE,
            InputBuffer: ?*const anyopaque,
            InputBufferLength: ULONG,
            OutputBuffer: ?*anyopaque,
            OutputBufferLength: ULONG,
        ) callconv(.winapi) NTSTATUS;
        /// Resolves a Win32 path against the process working directory and
        /// canonicalizes it, keeping any `\\?\` or `\\.\` prefix. Returns
        /// the byte length written excluding the terminator, the required
        /// byte length if the buffer is too small, or 0 on failure.
        pub extern "ntdll" fn RtlGetFullPathName_U(
            FileName: [*:0]const u16,
            BufferByteLength: ULONG,
            Buffer: [*]u16,
            ShortName: ?*[*:0]const u16,
        ) callconv(.winapi) ULONG;
        /// The futex primitives that kernel32's WaitOnAddress and
        /// WakeByAddress* forward to. Timeout is a relative (negative)
        /// interval in 100ns units, null to wait forever.
        pub extern "ntdll" fn RtlWaitOnAddress(
            Address: *const anyopaque,
            CompareAddress: *const anyopaque,
            AddressSize: SIZE_T,
            Timeout: ?*const LARGE_INTEGER,
        ) callconv(.winapi) NTSTATUS;
        pub extern "ntdll" fn RtlWakeAddressSingle(Address: *const anyopaque) callconv(.winapi) void;
        pub extern "ntdll" fn RtlWakeAddressAll(Address: *const anyopaque) callconv(.winapi) void;
    };
};

pub const ProcThreadAttributeNumber = enum(DWORD) {
    ProcThreadAttributePseudoConsole = 22,
    _,
};

/// Corresponds to the ProcThreadAttributeValue define in WinBase.h
pub fn ProcThreadAttributeValue(
    comptime attribute: ProcThreadAttributeNumber,
    comptime thread: bool,
    comptime input: bool,
    comptime additive: bool,
) DWORD {
    return (@backingInt(attribute) & PROC_THREAD_ATTRIBUTE_NUMBER) |
        (if (thread) PROC_THREAD_ATTRIBUTE_THREAD else 0) |
        (if (input) PROC_THREAD_ATTRIBUTE_INPUT else 0) |
        (if (additive) PROC_THREAD_ATTRIBUTE_ADDITIVE else 0);
}

/// The environment variable ghostty.com (src/main_launcher.zig) sets to
/// its process ID, in decimal, for the ghostty.exe it runs a CLI action in.
pub const launcher_env = std.unicode.utf8ToUtf16LeStringLiteral("GHOSTTY_LAUNCHER");

/// A process ID in decimal, as the launcher's value: the digits end `buf`.
pub fn formatPid(buf: *[10:0]u16, pid: DWORD) [:0]const u16 {
    // An undefined buffer's sentinel is undefined too.
    buf[buf.len] = 0;
    var i: usize = buf.len;
    var n = pid;
    while (true) {
        i -= 1;
        buf[i] = '0' + @as(u16, @intCast(n % 10));
        n /= 10;
        if (n == 0) break;
    }
    return buf[i..buf.len :0];
}

/// The process ID in a launcher value, or null when it is not one: empty,
/// anything but decimal digits, or over a DWORD.
pub fn parsePid(value: []const u16) ?DWORD {
    if (value.len == 0) return null;
    var pid: DWORD = 0;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
        pid = std.math.mul(DWORD, pid, 10) catch return null;
        pid = std.math.add(DWORD, pid, c - '0') catch return null;
    }
    return pid;
}

/// Whether ghostty.com started this process for a CLI action: the
/// launcher's value names this process's parent. A value inherited further
/// down (by a program an action starts, or anything that one starts) names
/// some other process, so it never counts there. The launcher waits for
/// ghostty.exe, so its ID cannot be reused meanwhile.
fn startedByLauncher() bool {
    var buf: [16]u16 = undefined;
    const len = exp.kernel32.GetEnvironmentVariableW(launcher_env, &buf, buf.len);
    if (len == 0 or len >= buf.len) return false;
    const pid = parsePid(buf[0..len]) orelse return false;
    var info: windows.PROCESS.BASIC_INFORMATION = undefined;
    if (windows.ntdll.NtQueryInformationProcess(
        windows.current_process,
        .BasicInformation,
        &info,
        @sizeOf(windows.PROCESS.BASIC_INFORMATION),
        null,
    ) != .SUCCESS) return false;
    return info.InheritedFromUniqueProcessId == pid;
}

/// Connects a CLI action (`ghostty +version`) that ghostty.com runs to
/// the launcher's console. ghostty.exe is a GUI-subsystem program, so
/// Windows gives it no console of its own: it inherits the launcher's std
/// handles but is not attached, and the console calls behind isatty and
/// the terminal UIs (+list-themes) fail. AttachConsole also gives a GUI
/// program the console's std handles where its parent passed none, and
/// keeps ones passed (a redirect).
/// https://learn.microsoft.com/en-us/windows/console/attachconsole
/// (Remarks).
///
/// Only under the launcher (startedByLauncher). ghostty.exe typed at a
/// prompt runs beside the shell, which does not wait for it and goes on
/// reading the same console, so an attached terminal UI (+list-themes,
/// +boo) would take keys meant for the prompt. It keeps what its parent
/// gave it instead, as any GUI program does: a file cmd redirects it to
/// gets the output, and the console gets nothing.
///
/// Console output also gets VT processing: once isatty says a terminal,
/// the actions write escape sequences (the OSC 8 link in +version,
/// colors), and cmd starts programs with it off, which prints them as
/// text. ghostty.com restores the mode after the action.
pub fn attachLauncherConsole() void {
    if (!startedByLauncher()) return;
    if (exp.kernel32.AttachConsole(ATTACH_PARENT_PROCESS) == FALSE) return;
    enableVirtualTerminal(STD_OUTPUT_HANDLE);
    enableVirtualTerminal(STD_ERROR_HANDLE);
}

fn enableVirtualTerminal(which: DWORD) void {
    const h = exp.kernel32.GetStdHandle(which) orelse return;
    var mode: DWORD = 0;
    if (exp.kernel32.GetConsoleMode(h, &mode) == FALSE) return;
    _ = exp.kernel32.SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
}
