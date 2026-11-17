//! Compiled shader bytecode, shared by every surface of the process.
//!
//! D3DCompile is the costly part of a surface's start: the built-in
//! pipelines take about 100 ms of it on each new window, tab or split
//! (ReleaseFast, arm64), and every surface compiles the same sources. DXBC
//! does not depend on the device it is created on, so a source compiles
//! once per process and every later surface creates its shaders from the
//! bytecode kept here.
//!
//! An entry is keyed by the SHA-256 of the target and the source. The
//! compile flags are not in the key: they are fixed by the build mode, and
//! the cache lives only as long as the process. A cache kept on disk would
//! need them in the key, and the compiler's version too.
//!
//! Entries are never removed: the built-in sources are a fixed set, and a
//! custom shader adds one entry per distinct source the process loads.
const ShaderCache = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

const api = @import("api.zig");
const global = @import("../../global.zig");

const log = std.log.scoped(.d3d11);

/// The process's cache, which every surface uses. It is never freed: like
/// the compiler module it fronts, it belongs to the process.
pub var process: ShaderCache = .init(std.heap.smp_allocator);

alloc: Allocator,

/// Held across a compile, so that surfaces created together (a restored
/// session's windows) compile a source once rather than each in parallel.
mutex: std.Io.Mutex = .init,

entries: std.AutoHashMapUnmanaged([Sha256.digest_length]u8, []const u8) = .empty,

pub const Error = error{ ShaderCompileFailed, OutOfMemory };

pub fn init(alloc: Allocator) ShaderCache {
    return .{ .alloc = alloc };
}

pub fn deinit(self: *ShaderCache) void {
    var it = self.entries.valueIterator();
    while (it.next()) |bytes| self.alloc.free(bytes.*);
    self.entries.deinit(self.alloc);
    self.* = undefined;
}

/// The bytecode of `source` compiled for `target` (entry point `main`),
/// compiled with `compile` unless the cache holds it. The slice lives as
/// long as the cache. A source that fails to compile is not kept: its
/// errors are logged each time it is asked for, as before the cache.
pub fn bytecode(
    self: *ShaderCache,
    compile: api.D3DCompileFn,
    name: []const u8,
    source: [:0]const u8,
    target: [:0]const u8,
) Error![]const u8 {
    const key = keyOf(source, target);

    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());

    const entry = try self.entries.getOrPut(self.alloc, key);
    if (entry.found_existing) return entry.value_ptr.*;
    errdefer self.entries.removeByPtr(entry.key_ptr);

    const blob = try compileShader(compile, name, source, target);
    defer api.release(blob);
    const bytes = try self.alloc.dupe(u8, blob.bytes());
    entry.value_ptr.* = bytes;
    return bytes;
}

fn keyOf(source: []const u8, target: []const u8) [Sha256.digest_length]u8 {
    var h: Sha256 = .init(.{});
    // The target's NUL separates it from the source: "ps_5_0" ++ "x" is
    // not "ps_5_0x" ++ "".
    h.update(target);
    h.update(&.{0});
    h.update(source);
    return h.finalResult();
}

/// Compile one shader stage. Debug builds keep the shader debuggable;
/// release builds optimize fully. The compiler's messages go to the log in
/// both cases: at warn level when it failed, as the caller decides what a
/// failure means (shaders.zig's initPostPipelines leaves a custom shader
/// out at warn; its PipelineDescription.initPipeline logs a built-in one's
/// failure as an error), and at debug level otherwise.
fn compileShader(
    compile: api.D3DCompileFn,
    name: []const u8,
    source: [:0]const u8,
    target: [:0]const u8,
) error{ShaderCompileFailed}!*api.ID3DBlob {
    const flags: api.UINT = api.D3DCOMPILE_ENABLE_STRICTNESS |
        if (comptime builtin.mode == .debug)
            api.D3DCOMPILE_DEBUG | api.D3DCOMPILE_SKIP_OPTIMIZATION
        else
            api.D3DCOMPILE_OPTIMIZATION_LEVEL3;

    var shader: ?*api.ID3DBlob = null;
    var messages: ?*api.ID3DBlob = null;
    const hr = compile(
        source.ptr,
        source.len,
        null,
        null,
        null,
        "main",
        target.ptr,
        flags,
        0,
        &shader,
        &messages,
    );
    defer if (messages) |m| api.release(m);

    if (api.failed(hr)) {
        if (shader) |s| api.release(s);
        log.warn("D3DCompile {s} ({s}) failed hr=0x{x}: {s}", .{
            name,
            target,
            @as(u32, @bitCast(hr)),
            if (messages) |m| trimMessages(m.bytes()) else "(no compiler output)",
        });
        return error.ShaderCompileFailed;
    }
    if (messages) |m| {
        const text = trimMessages(m.bytes());
        if (text.len > 0) log.debug("D3DCompile {s} ({s}): {s}", .{ name, target, text });
    }

    return shader orelse error.ShaderCompileFailed;
}

/// The compiler's text is NUL-terminated and ends with a newline.
fn trimMessages(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, 0) orelse text.len;
    return std.mem.trimEnd(u8, text[0..end], "\r\n ");
}

/// For tests: a D3DCompile that counts its calls and returns a blob of the
/// target and the source, or fails for a source that starts with "bad".
/// A blob's bytes are overwritten when it is released, so bytecode kept
/// past the blob's life shows up as wrong bytes.
pub const FakeCompiler = struct {
    pub var compiles: u32 = 0;
    pub var live_blobs: i32 = 0;

    const Blob = struct {
        blob: api.ID3DBlob = .{ .vtable = &vtable },
        data: []u8,

        const vtable: api.ID3DBlob.VTable = .{
            .base = .{ .QueryInterface = queryInterface, .AddRef = addRef, .Release = release },
            .GetBufferPointer = bufferPointer,
            .GetBufferSize = bufferSize,
        };

        fn of(u: anytype) *Blob {
            const b: *api.ID3DBlob = @ptrCast(@alignCast(u));
            return @fieldParentPtr("blob", b);
        }
        fn queryInterface(_: *api.IUnknown, _: api.REFIID, out: *?*anyopaque) callconv(api.cc) api.HRESULT {
            out.* = null;
            return api.E_FAIL;
        }
        fn addRef(_: *api.IUnknown) callconv(api.cc) api.ULONG {
            unreachable; // the cache never shares a blob
        }
        fn release(u: *api.IUnknown) callconv(api.cc) api.ULONG {
            const self = of(u);
            @memset(self.data, 0xAA);
            std.testing.allocator.free(self.data);
            std.testing.allocator.destroy(self);
            live_blobs -= 1;
            return 0;
        }
        fn bufferPointer(b: *api.ID3DBlob) callconv(api.cc) *anyopaque {
            return of(b).data.ptr;
        }
        fn bufferSize(b: *api.ID3DBlob) callconv(api.cc) api.SIZE_T {
            return of(b).data.len;
        }

        fn create(parts: []const []const u8) ?*api.ID3DBlob {
            const data = std.mem.concat(std.testing.allocator, u8, parts) catch return null;
            const self = std.testing.allocator.create(Blob) catch {
                std.testing.allocator.free(data);
                return null;
            };
            self.* = .{ .data = data };
            live_blobs += 1;
            return &self.blob;
        }
    };

    pub fn reset() void {
        compiles = 0;
        live_blobs = 0;
    }

    pub fn compile(
        data: *const anyopaque,
        data_size: api.SIZE_T,
        _: ?api.LPCSTR,
        _: ?[*]const api.D3D_SHADER_MACRO,
        _: ?*api.ID3DInclude,
        _: ?api.LPCSTR,
        target: api.LPCSTR,
        _: api.UINT,
        _: api.UINT,
        shader: *?*api.ID3DBlob,
        messages: ?*?*api.ID3DBlob,
    ) callconv(api.cc) api.HRESULT {
        compiles += 1;
        const source = @as([*]const u8, @ptrCast(data))[0..data_size];
        if (std.mem.startsWith(u8, source, "bad")) {
            shader.* = null;
            if (messages) |m| m.* = Blob.create(&.{"error X3000: bad source\n\x00"});
            return api.E_FAIL;
        }
        shader.* = Blob.create(&.{ std.mem.span(target), ":", source }) orelse return api.E_FAIL;
        if (messages) |m| m.* = null;
        return api.S_OK;
    }
};

test "d3d11 shader cache: a source compiles once per target, from then on from the cache" {
    const testing = std.testing;
    FakeCompiler.reset();
    var cache: ShaderCache = .init(testing.allocator);
    defer cache.deinit();
    const fake = &FakeCompiler.compile;

    const ps = try cache.bytecode(fake, "a", "float4 main()", "ps_5_0");
    try testing.expectEqualStrings("ps_5_0:float4 main()", ps);
    try testing.expectEqual(@as(u32, 1), FakeCompiler.compiles);
    // The blob is released; the bytes are the cache's own copy.
    try testing.expectEqual(@as(i32, 0), FakeCompiler.live_blobs);

    // The same source and target, under another pipeline's name: a hit,
    // the very bytes of the first.
    const again = try cache.bytecode(fake, "b", "float4 main()", "ps_5_0");
    try testing.expectEqual(@as(u32, 1), FakeCompiler.compiles);
    try testing.expectEqual(ps.ptr, again.ptr);

    // Another target, or another source: a compile each.
    const vs = try cache.bytecode(fake, "a", "float4 main()", "vs_5_0");
    try testing.expectEqualStrings("vs_5_0:float4 main()", vs);
    const other = try cache.bytecode(fake, "a", "float4 main() ", "ps_5_0");
    try testing.expectEqualStrings("ps_5_0:float4 main() ", other);
    try testing.expectEqual(@as(u32, 3), FakeCompiler.compiles);
    try testing.expectEqual(@as(usize, 3), cache.entries.count());

    // The first entries are untouched by the later ones.
    try testing.expectEqualStrings("ps_5_0:float4 main()", ps);
}

test "d3d11 shader cache: a source that fails to compile is not kept" {
    const testing = std.testing;
    FakeCompiler.reset();
    var cache: ShaderCache = .init(testing.allocator);
    defer cache.deinit();
    const fake = &FakeCompiler.compile;

    try testing.expectError(error.ShaderCompileFailed, cache.bytecode(fake, "custom shader", "bad", "ps_5_0"));
    try testing.expectError(error.ShaderCompileFailed, cache.bytecode(fake, "custom shader", "bad", "ps_5_0"));
    // Compiled, and failed, each time: no entry stands for the failure.
    try testing.expectEqual(@as(u32, 2), FakeCompiler.compiles);
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
    // The error blobs are released.
    try testing.expectEqual(@as(i32, 0), FakeCompiler.live_blobs);

    // A good source after a failure is kept as usual.
    _ = try cache.bytecode(fake, "a", "good", "ps_5_0");
    _ = try cache.bytecode(fake, "a", "good", "ps_5_0");
    try testing.expectEqual(@as(u32, 3), FakeCompiler.compiles);
}

test "d3d11 shader cache: the target is part of the key, not part of the source" {
    // "ps_5_0" with "x..." and "ps_5_0x" with "..." hash different bytes.
    const testing = std.testing;
    try testing.expect(!std.mem.eql(u8, &keyOf("x", "ps_5_0"), &keyOf("", "ps_5_0x")));
    try testing.expect(!std.mem.eql(u8, &keyOf("a", "ps_5_0"), &keyOf("a", "vs_5_0")));
    try testing.expectEqualSlices(u8, &keyOf("a", "ps_5_0"), &keyOf("a", "ps_5_0"));
}
