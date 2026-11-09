//! The `windows-packages` build step, which reports the packages the
//! Windows app links, so that dist/windows/make_zip.py can put their
//! licenses in the portable zip. It installs two files:
//!
//!   windows-packages.json       LibVtPackages.zig's report, with the app's
//!                               root module as its root instead of
//!                               libghostty-vt's: each package's hash,
//!                               version, linked paths and `.third_party`.
//!   windows-package-dirs.json   Where each package is, and what the
//!                               packages that depend on it call it:
//!
//!   {
//!     "packages": [
//!       { "hash": "", "dir": "/src/ghostty", "names": [] },
//!       { "hash": "N-V-__8AA...", "dir": "zig-pkg/N-V-__8AA...", "names": ["freetype"] },
//!       { "hash": "pkg/freetype", "dir": "pkg/freetype", "names": ["freetype"] },
//!       ...
//!     ]
//!   }
//!
//! A fetched C library has no build.zig.zon to name it, so its name comes
//! from the build.zig.zon that fetches it. Ghostty itself ("") has none.
//! Every directory but Ghostty's is as the build runner opens it: relative
//! to the directory `zig build` runs in, unless it is absolute. A path
//! dependency's hash is its path.
//!
//!   zig build windows-packages -Dtarget=x86_64-windows-gnu --prefix /tmp/report
const std = @import("std");
const LibVtPackages = @import("LibVtPackages.zig");

/// Defines the step for the app whose root module is `root`. Like
/// lib-vt-packages, the report is computed while build.zig runs, and a
/// malformed `.third_party` field fails only this step.
pub fn init(b: *std.Build, root: *std.Build.Module) error{OutOfMemory}!void {
    const step = b.step(
        "windows-packages",
        "Write windows-packages.json, the packages the Windows app links",
    );

    const report = LibVtPackages.report(b, root) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            step.dependOn(&b.addFail(b.fmt(
                "windows-packages: {t}, see the error above",
                .{err},
            )).step);
            return;
        },
    };

    const wf = b.addWriteFiles();
    for ([_]struct { []const u8, []const u8 }{
        .{ "windows-packages.json", report },
        .{ "windows-package-dirs.json", try dirs(b) },
    }) |file| step.dependOn(&b.addInstallFileWithDir(
        wf.add(file[0], file[1]),
        .prefix,
        file[0],
    ).step);
}

/// One entry in windows-package-dirs.json.
const Package = struct {
    hash: []const u8,
    dir: []const u8,
    names: []const []const u8,
};

/// Builds windows-package-dirs.json: Ghostty, then every package Zig
/// fetched or found for this build, sorted by hash. The build runner's
/// table (`std.Build.package_map`) holds each package's directory and the
/// name and hash of each of its dependencies; the root package's are in
/// `root_deps`.
fn dirs(b: *std.Build) error{OutOfMemory}![]const u8 {
    const arena = b.allocator;
    const map = std.Build.package_map;

    var names: std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    try addNames(arena, &names, @import("root").dependencies.root_deps);
    for (map.values()) |pkg| try addNames(arena, &names, pkg.deps);

    var packages: std.ArrayList(Package) = .empty;
    for (map.keys(), map.values()) |hash, pkg| {
        if (!pkg.available) continue;
        const found: [][]const u8 = if (names.getPtr(hash)) |list| list.items else &.{};
        std.mem.sort([]const u8, found, {}, lessThan);
        try packages.append(arena, .{ .hash = hash, .dir = pkg.build_root, .names = found });
    }
    std.mem.sort(Package, packages.items, {}, struct {
        fn f(_: void, l: Package, r: Package) bool {
            return lessThan({}, l.hash, r.hash);
        }
    }.f);
    try packages.insert(arena, 0, .{
        .hash = "",
        .dir = b.root.root_dir.path orelse ".",
        .names = &.{},
    });

    return std.json.Stringify.valueAlloc(
        arena,
        .{ .packages = packages.items },
        .{ .whitespace = .indent_2 },
    );
}

/// Records each (name, hash) of `deps` under its hash, once per name.
fn addNames(
    arena: std.mem.Allocator,
    names: *std.StringArrayHashMapUnmanaged(std.ArrayList([]const u8)),
    deps: anytype,
) error{OutOfMemory}!void {
    for (deps) |dep| {
        const name: []const u8, const hash: []const u8 = dep;
        const gop = try names.getOrPut(arena, hash);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        for (gop.value_ptr.items) |known| {
            if (std.mem.eql(u8, known, name)) break;
        } else try gop.value_ptr.append(arena, name);
    }
}

fn lessThan(_: void, l: []const u8, r: []const u8) bool {
    return std.mem.lessThan(u8, l, r);
}
