const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Checks if a hostname is local to the current machine. This matches
/// both "localhost" and the current hostname of the machine (as returned
/// by `gethostname`). On Windows, `localhost` or either of the machine's
/// names, ignoring case (`isWindowsName`).
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) return true;

    // If hostname is not "localhost" it must match our hostname.
    switch (builtin.target.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var netbios_buf: [256:0]u8 = undefined;
            var netbios_len: windows.DWORD = netbios_buf.len;
            var dns_buf: [256:0]u8 = undefined;
            var dns_len: windows.DWORD = dns_buf.len;
            return isWindowsName(
                hostname,
                if (windows.exp.kernel32.GetComputerNameA(&netbios_buf, &netbios_len) != windows.FALSE)
                    netbios_buf[0..netbios_len]
                else
                    null,
                if (windows.exp.kernel32.GetComputerNameExA(.DnsHostname, &dns_buf, &dns_len) != windows.FALSE)
                    dns_buf[0..dns_len]
                else
                    null,
            );
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const ourHostname = try posix.gethostname(&buf);
            return std.mem.eql(u8, hostname, ourHostname);
        },
    }
}

/// Whether `hostname` is one of a Windows machine's names, ignoring case
/// (host names are case-insensitive, RFC 4343): `localhost`, the NetBIOS
/// name (`$env:COMPUTERNAME`, upper case, at most 15 characters) or the
/// DNS host name (`[Net.Dns]::GetHostName()`, `hostname.exe`), which keeps
/// the case it was given and is the longer one when the name is over 15
/// characters. Either of the last two is null when Windows could not give
/// it. Apart from `isLocal` so that its tests do not depend on the
/// machine's names, which often differ only in case.
fn isWindowsName(hostname: []const u8, netbios: ?[]const u8, dns: ?[]const u8) bool {
    for ([_]?[]const u8{ "localhost", netbios, dns }) |name| {
        if (name) |n| if (std.ascii.eqlIgnoreCase(hostname, n)) return true;
    }
    return false;
}

test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
}

test "isLocal returns true when hostname is local" {
    switch (builtin.target.os.tag) {
        .windows => {
            const windows = @import("windows.zig");
            var buf: [256:0]u8 = undefined;
            var nSize: windows.DWORD = buf.len;
            if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE)
                return error.GetComputerNameFailed;
            const localHostname = buf[0..nSize];
            try std.testing.expect(try isLocal(localHostname));
        },
        else => {
            var buf: [posix.HOST_NAME_MAX]u8 = undefined;
            const localHostname = try posix.gethostname(&buf);
            try std.testing.expect(try isLocal(localHostname));
        },
    }
}

test "isLocal on windows takes either name, ignoring case" {
    const netbios = "BUILD-MACHINE-1";
    const dns = "Build-Machine-12";
    try std.testing.expect(isWindowsName("BUILD-MACHINE-1", netbios, dns));
    try std.testing.expect(isWindowsName("build-machine-1", netbios, dns));
    try std.testing.expect(isWindowsName("Build-Machine-12", netbios, dns));
    try std.testing.expect(isWindowsName("BUILD-MACHINE-12", netbios, dns));
    try std.testing.expect(!isWindowsName("build-machine", netbios, dns));
    try std.testing.expect(!isWindowsName("other", netbios, dns));
    try std.testing.expect(isWindowsName("LOCALHOST", netbios, dns));
    // A name Windows could not give matches nothing.
    try std.testing.expect(isWindowsName("build-machine-12", null, dns));
    try std.testing.expect(!isWindowsName("build-machine-1", null, dns));
    try std.testing.expect(!isWindowsName("", null, null));
    try std.testing.expect(isWindowsName("LocalHost", null, null));
}

test "isLocal ignores case and takes the DNS host name on windows" {
    if (comptime builtin.target.os.tag != .windows) return error.SkipZigTest;

    const windows = @import("windows.zig");
    var buf: [256:0]u8 = undefined;
    var nSize: windows.DWORD = buf.len;
    if (windows.exp.kernel32.GetComputerNameA(&buf, &nSize) == windows.FALSE)
        return error.GetComputerNameFailed;
    const lower = std.ascii.lowerString(buf[0..nSize], buf[0..nSize]);
    try std.testing.expect(try isLocal(lower));

    nSize = buf.len;
    if (windows.exp.kernel32.GetComputerNameExA(.DnsHostname, &buf, &nSize) == windows.FALSE)
        return error.GetComputerNameFailed;
    try std.testing.expect(try isLocal(buf[0..nSize]));
    const upper = std.ascii.upperString(buf[0..nSize], buf[0..nSize]);
    try std.testing.expect(try isLocal(upper));
}

test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );
}
