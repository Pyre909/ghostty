//! GPU buffers for a fixed element type: constant buffers for uniforms,
//! vertex buffers for instances, structured buffers the shaders read.
const std = @import("std");
const Allocator = std.mem.Allocator;

const api = @import("api.zig");

const log = std.log.scoped(.d3d11);

/// How a buffer is bound, which decides its bind flags and views.
pub const Kind = enum {
    /// A constant buffer (`cbuffer`); sizes are rounded up to 16 bytes.
    constant,
    /// An input-assembler vertex or instance buffer.
    vertex,
    /// A structured buffer read through a shader resource view.
    structured,
};

pub const Options = struct {
    device: *api.ID3D11Device,
    context: *api.ID3D11DeviceContext,
    kind: Kind,
};

/// What a render step receives for a buffer: the buffer, and for structured
/// buffers the view it is read through.
pub const Handle = struct {
    buffer: *api.ID3D11Buffer,
    srv: ?*api.ID3D11ShaderResourceView = null,

    fn release(self: Handle) void {
        if (self.srv) |v| api.release(v);
        api.release(self.buffer);
    }
};

/// Direct3D 11 refuses zero-sized buffers, and constant buffers must be a
/// multiple of 16 bytes.
fn byteWidth(bytes: usize) api.UINT {
    const width = @max(bytes, 16);
    return @intCast((width + 15) & ~@as(usize, 15));
}

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        /// The options this buffer was initialized with.
        opts: Options,

        /// What steps are given for this buffer.
        buffer: Handle,

        /// The allocated length of the buffer, in `T`s, not bytes.
        len: usize,

        /// Whether the buffer can be written after creation.
        dynamic: bool,

        /// Initialize a buffer with the given length pre-allocated. It is
        /// dynamic: `sync` writes it through a map.
        pub fn init(opts: Options, len: usize) !Self {
            const handle = try create(opts, len, null);
            return .{
                .opts = opts,
                .buffer = handle,
                .len = len,
                .dynamic = true,
            };
        }

        /// Init the buffer filled with the given data, immutable from then
        /// on.
        pub fn initFill(opts: Options, data: []const T) !Self {
            const handle = try create(opts, data.len, data);
            return .{
                .opts = opts,
                .buffer = handle,
                .len = data.len,
                .dynamic = false,
            };
        }

        pub fn deinit(self: *const Self) void {
            self.buffer.release();
        }

        fn create(opts: Options, len: usize, initial: ?[]const T) !Handle {
            const desc: api.D3D11_BUFFER_DESC = .{
                .ByteWidth = byteWidth(@max(len, 1) * @sizeOf(T)),
                .Usage = if (initial != null) .IMMUTABLE else .DYNAMIC,
                .BindFlags = switch (opts.kind) {
                    .constant => api.D3D11_BIND_CONSTANT_BUFFER,
                    .vertex => api.D3D11_BIND_VERTEX_BUFFER,
                    .structured => api.D3D11_BIND_SHADER_RESOURCE,
                },
                .CPUAccessFlags = if (initial != null) 0 else api.D3D11_CPU_ACCESS_WRITE,
                .MiscFlags = switch (opts.kind) {
                    .structured => api.D3D11_RESOURCE_MISC_BUFFER_STRUCTURED,
                    else => 0,
                },
                .StructureByteStride = switch (opts.kind) {
                    .structured => @sizeOf(T),
                    else => 0,
                },
            };

            const init_data: ?api.D3D11_SUBRESOURCE_DATA = if (initial) |d| .{
                .pSysMem = d.ptr,
                .SysMemPitch = 0,
                .SysMemSlicePitch = 0,
            } else null;

            var buffer_ptr: ?*api.ID3D11Buffer = null;
            var hr = opts.device.vtable.CreateBuffer(
                opts.device,
                &desc,
                if (init_data) |*d| d else null,
                &buffer_ptr,
            );
            if (api.failed(hr)) {
                log.err("CreateBuffer kind={s} bytes={d} failed hr=0x{x}", .{
                    @tagName(opts.kind),
                    desc.ByteWidth,
                    @as(u32, @bitCast(hr)),
                });
                return error.D3D11Failed;
            }
            const buffer = buffer_ptr orelse return error.D3D11Failed;
            errdefer api.release(buffer);

            var srv: ?*api.ID3D11ShaderResourceView = null;
            if (opts.kind == .structured) {
                var view_desc: api.D3D11_SHADER_RESOURCE_VIEW_DESC = .{
                    .Format = .UNKNOWN,
                    .ViewDimension = .BUFFEREX,
                    .u = .{ .BufferEx = .{
                        .FirstElement = 0,
                        .NumElements = @intCast(desc.ByteWidth / @sizeOf(T)),
                        .Flags = 0,
                    } },
                };
                hr = opts.device.vtable.CreateShaderResourceView(
                    opts.device,
                    buffer.resource(),
                    &view_desc,
                    &srv,
                );
                if (api.failed(hr)) {
                    log.err("CreateShaderResourceView for a structured buffer failed hr=0x{x}", .{
                        @as(u32, @bitCast(hr)),
                    });
                    return error.D3D11Failed;
                }
            }

            return .{ .buffer = buffer, .srv = srv };
        }

        /// Sync new contents to the buffer. The data is expected to be the
        /// complete contents of the buffer. If the amount of data is larger
        /// than the buffer length, the buffer will be reallocated.
        ///
        /// Unlike the other backends, bytes past the data are undefined
        /// after a sync: the buffer is mapped with WRITE_DISCARD (see
        /// `map`), and every caller draws only what it synced.
        pub fn sync(self: *Self, data: []const T) !void {
            try self.ensureCapacity(data.len);
            const dst = try self.map();
            defer self.unmap();
            const bytes = data.len * @sizeOf(T);
            @memcpy(dst[0..bytes], @as([*]const u8, @ptrCast(data.ptr))[0..bytes]);
        }

        /// Like Buffer.sync but takes data from an array of ArrayLists,
        /// rather than a single array. Returns the number of items synced.
        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            var total_len: usize = 0;
            for (lists) |list| total_len += list.items.len;

            try self.ensureCapacity(total_len);
            const dst = try self.map();
            defer self.unmap();

            var i: usize = 0;
            for (lists) |list| {
                const bytes = list.items.len * @sizeOf(T);
                @memcpy(dst[i..][0..bytes], @as([*]const u8, @ptrCast(list.items.ptr))[0..bytes]);
                i += bytes;
            }

            return total_len;
        }

        /// Reallocate at double the required size when the buffer is too
        /// small, as the other backends do. The old contents are not
        /// carried over; every sync rewrites the buffer from the start.
        fn ensureCapacity(self: *Self, len: usize) !void {
            if (!self.dynamic) return error.D3D11BufferImmutable;
            if (len <= self.len) return;
            const new_len = len * 2;
            const handle = try create(self.opts, new_len, null);
            self.buffer.release();
            self.buffer = handle;
            self.len = new_len;
        }

        /// The whole buffer, write-only, discarding the previous contents.
        /// Every sync writes the complete contents, so nothing is lost.
        fn map(self: *Self) ![]u8 {
            var mapped: api.D3D11_MAPPED_SUBRESOURCE = undefined;
            const ctx = self.opts.context;
            const hr = ctx.vtable.Map(ctx, self.buffer.buffer.resource(), 0, .WRITE_DISCARD, 0, &mapped);
            if (api.failed(hr)) {
                log.warn("Map failed hr=0x{x}", .{@as(u32, @bitCast(hr))});
                return error.D3D11Failed;
            }
            const ptr: [*]u8 = @ptrCast(mapped.pData orelse return error.D3D11Failed);
            return ptr[0 .. self.len * @sizeOf(T)];
        }

        fn unmap(self: *Self) void {
            const ctx = self.opts.context;
            ctx.vtable.Unmap(ctx, self.buffer.buffer.resource(), 0);
        }
    };
}

test "d3d11 buffer: byte widths" {
    const testing = std.testing;
    try testing.expectEqual(16, byteWidth(0));
    try testing.expectEqual(16, byteWidth(4));
    try testing.expectEqual(16, byteWidth(16));
    try testing.expectEqual(32, byteWidth(17));
    try testing.expectEqual(4096, byteWidth(4096));
}
