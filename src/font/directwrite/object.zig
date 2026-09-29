//! COM objects implemented here, for the interfaces DirectWrite calls
//! back: the text a font fallback reads, and later the loader and the
//! stream that serve it fonts from memory.
//!
//! An object is a reference count and the state of its implementation
//! behind the interface pointer that COM sees, which is a pointer to a
//! pointer to the vtable. The interface is a field of the object rather
//! than its first bytes, and the object is recovered from the interface
//! pointer by that field, so nothing depends on how the object is laid
//! out.
//!
//! Nothing here calls DirectWrite, and the methods have the calling
//! convention of the bindings, which is the C one off Windows: the tests
//! call an object through its vtable on every host, as DirectWrite would.
const std = @import("std");
const Allocator = std.mem.Allocator;
const api = @import("api.zig");

/// An object that implements `Interface`, whose vtable starts with
/// IUnknown's three methods, with `Impl` as its state.
///
/// `Impl` declares what the object answers to beside IUnknown as
/// `pub const iids: []const *const api.GUID`, and may declare `deinit` to
/// release what it holds when the last reference goes.
pub fn Object(comptime Interface: type, comptime Impl: type) type {
    return struct {
        const Self = @This();

        interface: Interface,
        refs: std.atomic.Value(u32),
        alloc: Allocator,
        impl: Impl,

        /// IUnknown's part of the vtable, for the implementation to put
        /// at the start of its own.
        pub const unknown: api.IUnknown.VTable = .{
            .QueryInterface = queryInterface,
            .AddRef = addRef,
            .Release = release,
        };

        /// A new object with one reference, which is the caller's and
        /// which `api.release` on its interface gives up.
        pub fn create(
            alloc: Allocator,
            vtable: *const Interface.VTable,
            impl: Impl,
        ) Allocator.Error!*Self {
            const self = try alloc.create(Self);
            self.* = .{
                .interface = .{ .vtable = vtable },
                .refs = .init(1),
                .alloc = alloc,
                .impl = impl,
            };
            return self;
        }

        /// The object behind an interface pointer that one of its methods
        /// was called with.
        pub fn from(this: *Interface) *Self {
            return @fieldParentPtr("interface", this);
        }

        fn fromUnknown(this: *api.IUnknown) *Self {
            return from(@ptrCast(@alignCast(this)));
        }

        fn queryInterface(
            this: *api.IUnknown,
            riid: api.REFIID,
            out: *?*anyopaque,
        ) callconv(api.cc) api.HRESULT {
            const self = fromUnknown(this);
            const known = known: {
                if (std.meta.eql(riid.*, api.IID_IUnknown)) break :known true;
                for (Impl.iids) |iid| {
                    if (std.meta.eql(riid.*, iid.*)) break :known true;
                }
                break :known false;
            };
            if (!known) {
                out.* = null;
                return api.E_NOINTERFACE;
            }

            _ = self.refs.fetchAdd(1, .monotonic);
            out.* = &self.interface;
            return api.S_OK;
        }

        fn addRef(this: *api.IUnknown) callconv(api.cc) api.ULONG {
            const self = fromUnknown(this);
            return self.refs.fetchAdd(1, .monotonic) + 1;
        }

        fn release(this: *api.IUnknown) callconv(api.cc) api.ULONG {
            const self = fromUnknown(this);
            const left = self.refs.fetchSub(1, .acq_rel) - 1;
            if (left == 0) {
                if (@hasDecl(Impl, "deinit")) self.impl.deinit();
                const alloc = self.alloc;
                alloc.destroy(self);
            }
            return left;
        }
    };
}

test "directwrite object: references and interfaces" {
    const testing = std.testing;

    // An interface of one method beside IUnknown's, and an implementation
    // that counts how often it was torn down.
    const Counter = extern struct {
        vtable: *const VTable,

        const Self = @This();
        pub const IID: api.GUID = api.GUID.parse("{c0ffee00-0001-4a6f-8a3b-5d1e0f2a9b7c}");
        const VTable = extern struct {
            base: api.IUnknown.VTable,
            Get: *const fn (*Self) callconv(api.cc) api.UINT,
        };
    };
    const other_iid: api.GUID = api.GUID.parse("{c0ffee00-0002-4a6f-8a3b-5d1e0f2a9b7c}");

    const Impl = struct {
        value: api.UINT,
        torn_down: *usize,

        pub const iids: []const *const api.GUID = &.{&Counter.IID};

        pub fn deinit(self: *@This()) void {
            self.torn_down.* += 1;
        }
    };
    const Obj = Object(Counter, Impl);
    const vtable: Counter.VTable = .{
        .base = Obj.unknown,
        .Get = struct {
            fn get(this: *Counter) callconv(api.cc) api.UINT {
                return Obj.from(this).impl.value;
            }
        }.get,
    };

    var torn_down: usize = 0;
    const obj = try Obj.create(testing.allocator, &vtable, .{
        .value = 42,
        .torn_down = &torn_down,
    });
    const counter: *Counter = &obj.interface;

    // The interface pointer is what a caller of COM holds: a pointer to
    // the vtable pointer, through which the methods are reached.
    try testing.expectEqual(42, counter.vtable.Get(counter));

    // It answers to IUnknown and to its own interface, with a reference
    // each, and to nothing else.
    const unk = try api.queryInterface(counter, api.IUnknown);
    try testing.expectEqual(@intFromPtr(counter), @intFromPtr(unk));
    const again = try api.queryInterface(counter, Counter);
    try testing.expectEqual(@intFromPtr(counter), @intFromPtr(again));
    var out: ?*anyopaque = @ptrFromInt(0x1000);
    try testing.expectEqual(
        api.E_NOINTERFACE,
        unk.vtable.QueryInterface(unk, &other_iid, &out),
    );
    try testing.expect(out == null);

    // Three references by now. The object lives until the last is gone,
    // and is torn down once.
    try testing.expectEqual(4, unk.vtable.AddRef(unk));
    try testing.expectEqual(3, unk.vtable.Release(unk));
    api.release(again);
    api.release(unk);
    try testing.expectEqual(0, torn_down);
    try testing.expectEqual(0, unk.vtable.Release(unk));
    try testing.expectEqual(1, torn_down);
}
