//! The update feed: a JSON file published with each release of the
//! Windows build, which says the newest version, where its release notes
//! are, and the installer package for each architecture with its SHA-256:
//!
//!     {
//!       "version": "1.4.1-win.3",
//!       "notes": "https://github.com/<owner>/<repo>/releases/tag/<tag>",
//!       "packages": {
//!         "x86_64": { "url": ".../releases/download/<tag>/<name>.msi", "sha256": "<64 hex>" },
//!         "aarch64": { "url": "...", "sha256": "..." }
//!       }
//!     }
//!
//! `parse` decides from it whether this build should update, and to what.
//! What it accepts is narrow on purpose, as the URLs it returns are
//! downloaded and run, and opened in the browser: both must be under
//! the releases page the build names (`releases`, an HTTPS URL but in
//! tests, which serve the feed on a loopback port), the download a
//! `.msi` of plain path segments, and the version semantic (semver.org),
//! newer than this build's by semver's precedence. Unknown fields are
//! ignored, so that a later feed can add some.
//!
//! A build that installs updates first checks the feed's signature
//! (`verify`), which dist/windows/make_feed.py writes beside it: only
//! then does the package's hash say who published the package, rather
//! than only that it is the one the feed names.

const std = @import("std");
const Allocator = std.mem.Allocator;
const SemanticVersion = std.SemanticVersion;

/// The architectures packages are built for, by their feed key.
pub const Arch = enum {
    x86_64,
    aarch64,

    /// This build's, or null where no package is built.
    pub fn native() ?Arch {
        return switch (@import("builtin").cpu.arch) {
            .x86_64 => .x86_64,
            .aarch64 => .aarch64,
            else => null,
        };
    }
};

/// A newer version this build can update to. Its slices are the
/// allocator's that `parse` was given.
pub const Update = struct {
    version: []const u8,
    /// The release's page, or null if the feed names none.
    notes: ?[]const u8,
    /// This architecture's installer package.
    url: []const u8,
    sha256: [32]u8,
};

pub const Error = error{
    /// Not JSON of the feed's shape, or a field not as described above.
    InvalidFeed,
    /// The feed's version, or this build's, is not semantic.
    InvalidVersion,
    /// The feed has no package for this architecture.
    NoPackage,
    /// A URL outside what `releases` allows.
    UrlNotAllowed,
    OutOfMemory,
};

/// Whether `signature`, the feed's signature file, is an Ed25519
/// signature of `body`, its exact bytes, by the key whose public half is
/// `public_key` (the build's, `-Dupdate-public-key`).
pub fn verify(body: []const u8, signature: []const u8, public_key: [32]u8) error{BadSignature}!void {
    const Ed25519 = std.crypto.sign.Ed25519;
    if (signature.len != Ed25519.Signature.encoded_length) return error.BadSignature;
    const sig: Ed25519.Signature = .fromBytes(signature[0..Ed25519.Signature.encoded_length].*);
    const key = Ed25519.PublicKey.fromBytes(public_key) catch return error.BadSignature;
    sig.verify(body, key) catch return error.BadSignature;
}

const Package = struct {
    url: []const u8,
    sha256: []const u8,
};

const Feed = struct {
    version: []const u8,
    notes: ?[]const u8 = null,
    packages: struct {
        x86_64: ?Package = null,
        aarch64: ?Package = null,
    },
};

/// The update `body` (the feed) offers a build of version `current` on
/// `arch`, or null if the feed's version is not newer. `releases` is the
/// releases page's URL, ending in "/releases/", under which the notes and
/// the package must be. Allocates from `arena`, which should be one: the
/// parse leaves what it allocates there, and the result points into it.
pub fn parse(
    arena: Allocator,
    body: []const u8,
    current: []const u8,
    arch: Arch,
    releases: []const u8,
) Error!?Update {
    std.debug.assert(std.mem.endsWith(u8, releases, "/releases/"));

    const feed = std.json.parseFromSliceLeaky(Feed, arena, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidFeed,
    };

    const offered = try orderable(feed.version);
    const running = try orderable(current);
    if (offered.order(running) != .gt) return null;

    const package = switch (arch) {
        .x86_64 => feed.packages.x86_64,
        .aarch64 => feed.packages.aarch64,
    } orelse return error.NoPackage;
    if (!allowed(package.url, releases, "download/", ".msi")) return error.UrlNotAllowed;
    if (feed.notes) |notes| {
        if (!allowed(notes, releases, "", "")) return error.UrlNotAllowed;
    }
    var sha256: [32]u8 = undefined;
    if (package.sha256.len != 2 * sha256.len) return error.InvalidFeed;
    _ = std.fmt.hexToBytes(&sha256, package.sha256) catch return error.InvalidFeed;

    return .{
        .version = feed.version,
        .notes = feed.notes,
        .url = package.url,
        .sha256 = sha256,
    };
}

/// `text` parsed as a version `SemanticVersion.order` can compare. order
/// reads every pre-release identifier with `parseUnsigned` and takes an
/// overflow as unreachable, which parse rules out only for identifiers
/// of digits alone: one of more digits than a usize holds, then a letter,
/// is a valid alphanumeric identifier, yet overflows before the letter.
/// So each identifier is read here as order reads it.
fn orderable(text: []const u8) Error!SemanticVersion {
    const version = SemanticVersion.parse(text) catch return error.InvalidVersion;
    var ids = std.mem.splitScalar(u8, version.pre orelse "", '.');
    while (ids.next()) |id| {
        _ = std.fmt.parseUnsigned(usize, id, 10) catch |err| switch (err) {
            error.Overflow => return error.InvalidVersion,
            error.InvalidCharacter => {},
        };
    }
    return version;
}

/// Whether `url` is `releases` then `under`, then one or more path
/// segments of letters, digits and `.-_+` (none of them `.` or `..`),
/// the last ending in `suffix`: no query, fragment, escape, host or user
/// of another, and nothing a path could climb out with.
fn allowed(url: []const u8, releases: []const u8, under: []const u8, suffix: []const u8) bool {
    if (!std.mem.startsWith(u8, url, releases)) return false;
    const rest = url[releases.len..];
    if (!std.mem.startsWith(u8, rest, under)) return false;
    const path = rest[under.len..];
    if (path.len == 0 or !std.mem.endsWith(u8, path, suffix)) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-', '_', '+' => {},
            else => return false,
        };
    }
    return true;
}

const testing = std.testing;
const test_releases = "https://github.com/owner/repo/releases/";
const test_sha = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

/// A feed of `version` with one x86_64 package at `url`, notes `notes`.
fn testFeed(buf: []u8, version: []const u8, url: []const u8, notes: []const u8) []const u8 {
    return std.fmt.bufPrint(buf,
        \\{{"version":"{s}","notes":"{s}","packages":{{"x86_64":{{"url":"{s}","sha256":"{s}"}}}}}}
    , .{ version, notes, url, test_sha }) catch unreachable;
}

const test_url = test_releases ++ "download/v1.4.1-win.3/ghostty-x86_64.msi";
const test_notes = test_releases ++ "tag/v1.4.1-win.3";

test "win32: a newer feed is an update, its package and hash this arch's" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const body = testFeed(&buf, "1.4.1-win.3", test_url, test_notes);
    const update = (try parse(arena.allocator(), body, "1.4.1-win.2", .x86_64, test_releases)).?;
    try testing.expectEqualStrings("1.4.1-win.3", update.version);
    try testing.expectEqualStrings(test_url, update.url);
    try testing.expectEqualStrings(test_notes, update.notes.?);
    try testing.expectEqual(@as(u8, 0x00), update.sha256[0]);
    try testing.expectEqual(@as(u8, 0x11), update.sha256[1]);
    try testing.expectEqual(@as(u8, 0xff), update.sha256[31]);

    // No package for the other architecture.
    try testing.expectError(error.NoPackage, parse(arena.allocator(), body, "1.4.1-win.2", .aarch64, test_releases));
}

test "win32: a feed no newer than the build is no update, by semver's precedence" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    const Case = struct { offered: []const u8, current: []const u8, update: bool };
    for ([_]Case{
        .{ .offered = "1.4.1-win.3", .current = "1.4.1-win.3", .update = false },
        .{ .offered = "1.4.1-win.3", .current = "1.4.1-win.4", .update = false },
        // Numeric identifiers compare as numbers, not text.
        .{ .offered = "1.4.1-win.10", .current = "1.4.1-win.9", .update = true },
        .{ .offered = "1.4.2-win.1", .current = "1.4.1-win.9", .update = true },
        .{ .offered = "1.4.1-win.9", .current = "1.4.2-win.1", .update = false },
        // Build metadata takes no part.
        .{ .offered = "1.4.1-win.3+abc", .current = "1.4.1-win.3+def", .update = false },
        // A release is newer than its pre-releases.
        .{ .offered = "1.5.0", .current = "1.5.0-win.1", .update = true },
    }) |case| {
        const body = testFeed(&buf, case.offered, test_url, test_notes);
        const got = try parse(arena.allocator(), body, case.current, .x86_64, test_releases);
        testing.expectEqual(case.update, got != null) catch |err| {
            std.debug.print("offered {s} over {s}\n", .{ case.offered, case.current });
            return err;
        };
    }
}

test "win32: a feed's URLs must be under the build's releases, a download an .msi" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    for ([_][]const u8{
        "http://github.com/owner/repo/releases/download/v1/g.msi",
        "https://github.com/owner/other/releases/download/v1/g.msi",
        "https://github.com/owner/repo/releases/download/v1/g.exe",
        "https://github.com/owner/repo/releases/tag/v1/g.msi",
        "https://github.com/owner/repo/releases/download/../../other/g.msi",
        "https://github.com/owner/repo/releases/download/v1/./g.msi",
        "https://github.com/owner/repo/releases/download//g.msi",
        "https://github.com/owner/repo/releases/download/v1/g.msi?x=.msi",
        "https://github.com/owner/repo/releases/download/v1/g%2e.msi",
        "https://github.com/owner/repo/releases/download/v1/g.msi#.msi",
        "https://github.com/owner/repo/releases/download/",
        "https://github.com/owner/repo/releases/download/.msi/",
    }) |url| {
        const body = testFeed(&buf, "9.0.0", url, test_notes);
        testing.expectError(error.UrlNotAllowed, parse(arena.allocator(), body, "1.0.0", .x86_64, test_releases)) catch |err| {
            std.debug.print("allowed: {s}\n", .{url});
            return err;
        };
    }
    for ([_][]const u8{
        "https://example.com/owner/repo/releases/tag/v1",
        "javascript:alert(1)",
        "https://github.com/owner/repo/releases/",
        "https://github.com/owner/repo/releases/tag/v1?x",
    }) |notes| {
        const body = testFeed(&buf, "9.0.0", test_url, notes);
        try testing.expectError(error.UrlNotAllowed, parse(arena.allocator(), body, "1.0.0", .x86_64, test_releases));
    }
    // Allowed: a plus in a name, as a version's build metadata has one.
    const body = testFeed(&buf, "9.0.0", test_releases ++ "download/v9.0.0/g-9.0.0+x.msi", test_notes);
    try testing.expect(try parse(arena.allocator(), body, "1.0.0", .x86_64, test_releases) != null);
}

test "win32: a feed not of the feed's shape is refused, unknown fields aside" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectError(error.InvalidFeed, parse(a, "", "1.0.0", .x86_64, test_releases));
    try testing.expectError(error.InvalidFeed, parse(a, "<html>", "1.0.0", .x86_64, test_releases));
    try testing.expectError(error.InvalidFeed, parse(a, "{\"version\":\"9.0.0\"}", "1.0.0", .x86_64, test_releases));
    try testing.expectError(error.InvalidVersion, parse(a,
        \\{"version":"9","packages":{}}
    , "1.0.0", .x86_64, test_releases));
    try testing.expectError(error.InvalidVersion, parse(a,
        \\{"version":"9.0.0","packages":{}}
    , "not-a-version", .x86_64, test_releases));
    // An identifier past usize, of digits alone (which parse refuses) or
    // then a letter (which parse takes, but order cannot compare): both
    // refused, in the feed and in the build's own version.
    for ([_][]const u8{ "1.4.1-win.99999999999999999999999", "1.4.1-win.99999999999999999999999a" }) |version| {
        var buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"version":"{s}","packages":{{}}}}
        , .{version}) catch unreachable;
        try testing.expectError(error.InvalidVersion, parse(a, body, "1.4.1-win.3", .x86_64, test_releases));
        try testing.expectError(error.InvalidVersion, parse(a,
            \\{"version":"1.4.1-win.3","packages":{}}
        , version, .x86_64, test_releases));
    }
    // The largest that fits, then a letter: compared.
    try testing.expectEqual(null, try parse(a,
        \\{"version":"1.4.1-win.18446744073709551615a","packages":{}}
    , "1.4.1-win.18446744073709551615b", .x86_64, test_releases));
    // A hash not 64 hex digits.
    for ([_][]const u8{ "00", test_sha ++ "00", "zz" ++ test_sha[2..] }) |sha| {
        var buf: [1024]u8 = undefined;
        const body = std.fmt.bufPrint(&buf,
            \\{{"version":"9.0.0","packages":{{"x86_64":{{"url":"{s}","sha256":"{s}"}}}}}}
        , .{ test_url, sha }) catch unreachable;
        try testing.expectError(error.InvalidFeed, parse(a, body, "1.0.0", .x86_64, test_releases));
    }
    // Unknown fields, and no notes: still an update.
    const body =
        \\{"version":"9.0.0","later":{"x":[1]},"packages":{"x86_64":{"url":"
    ++ test_url ++
        \\","sha256":"
    ++ test_sha ++
        \\","size":5},"riscv64":{"url":"x","sha256":"y"}}}
    ;
    const update = (try parse(a, body, "1.0.0", .x86_64, test_releases)).?;
    try testing.expect(update.notes == null);
}

test "win32: the feed make_feed.py writes and signs verifies, and parses for each arch" {
    // testdata's feed and signature are byte for byte what make_feed.py
    // writes for two packages (dist/windows/test_make_feed.py), signed
    // with RFC 8032's first test key (section 7.1, TEST 1).
    const Ed25519 = std.crypto.sign.Ed25519;
    const feed = @embedFile("testdata/ghostty-windows-update.json");
    const signature = @embedFile("testdata/ghostty-windows-update.json.sig");
    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&seed, "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60");
    var public_key: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&public_key, "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a");
    const pair = try Ed25519.KeyPair.generateDeterministic(seed);
    try std.testing.expectEqualSlices(u8, &public_key, &pair.public_key.toBytes());

    try verify(feed, signature, public_key);
    // Any other bytes, signature or key: refused.
    var changed = feed.*;
    changed[changed.len - 2] ^= 1;
    try std.testing.expectError(error.BadSignature, verify(&changed, signature, public_key));
    var forged = signature.*;
    forged[0] ^= 1;
    try std.testing.expectError(error.BadSignature, verify(feed, &forged, public_key));
    try std.testing.expectError(error.BadSignature, verify(feed, signature[0 .. signature.len - 1], public_key));
    const other = try Ed25519.KeyPair.generateDeterministic(@splat(1));
    try std.testing.expectError(error.BadSignature, verify(feed, signature, other.public_key.toBytes()));
    const own = try other.sign(feed, null);
    try std.testing.expectError(error.BadSignature, verify(feed, &own.toBytes(), public_key));

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const releases = "https://github.com/Pyre909/ghostty/releases/";
    inline for (.{ .{ Arch.x86_64, "x86_64", "x64" }, .{ Arch.aarch64, "aarch64", "arm" } }) |case| {
        const update = (try parse(arena.allocator(), feed, "1.0.0", case[0], releases)).?;
        try std.testing.expectEqualStrings("1.4.1-win.3", update.version);
        try std.testing.expectEqualStrings(releases ++ "tag/v1.4.1-win.3", update.notes.?);
        try std.testing.expectEqualStrings(releases ++ "download/v1.4.1-win.3/ghostty-1.4.1-win.3-windows-" ++ case[1] ++ ".msi", update.url);
        var sha256: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(case[2], &sha256, .{});
        try std.testing.expectEqualSlices(u8, &sha256, &update.sha256);
    }
    try std.testing.expectEqual(null, try parse(arena.allocator(), feed, "1.4.1-win.3", .x86_64, releases));
}
