//! Checks hand-written COM declarations against the Windows SDK headers.
//!
//! The Windows code declares the COM interfaces it calls as Zig vtable
//! structs, copied by hand from the mingw headers Zig ships. A slot dropped,
//! shuffled or given the wrong signature still compiles, and the first sign
//! of it is a call into the wrong function on a Windows machine. This file
//! compares those declarations, at compile time, with translate-c's
//! translation of the same headers, which a Windows test build imports as
//! `windows-com-h` (see `src/build/c_deps.zig`).
//!
//! For a vtable the check flattens both sides (a Zig vtable embeds its
//! parent's as a `base` field; the C one lists every slot) and requires the
//! same number of slots, with the same name at each index. A slot the Zig
//! side types must also take the same parameters and return the same type,
//! compared by shape:
//!
//!   - integers and enums by width and signedness (translate-c makes every
//!     C enum a plain integer),
//!   - pointers by constness and by what they point at, named structs and
//!     interfaces by name, so a pointer to the wrong interface or struct
//!     fails; a `void` pointer on either side matches any pointer,
//!   - structs passed by value by name.
//!
//! The first parameter, the object itself, need only be a pointer: an
//! implementation names its own type there. An untyped slot is checked by
//! name and index only.
//!
//! For a struct the check requires the same size and alignment, and the
//! same fields in order: the same names, offsets and sizes, and types of the
//! same shape. Where the header has an anonymous union, each member the Zig
//! side declares in its place must be one of the union's.
//!
//! What it cannot see: two parameters of the same shape swapped, enum
//! values (translate-c keeps no enum types), interface ids, and mistakes in
//! the headers themselves.
//!
//! `mismatches` only reads types, so it runs for any target; the self tests
//! below check it on hand-made "C" declarations. Against the real headers it
//! must run for a Windows target, since a C `long` is 64 bits elsewhere.
const std = @import("std");

/// A Zig declaration and the name of its C counterpart: for an interface,
/// the C interface name (`ID3D11Device`, compared with `ID3D11DeviceVtbl`);
/// for a struct, the C typedef name.
pub const Entry = struct {
    zig: type,
    c: []const u8,
};

/// Every mismatch between `entries` and the translated headers `c`, one per
/// line, or an empty string. Each line names the Zig type and the C one.
pub fn mismatches(comptime c: type, comptime entries: []const Entry) []const u8 {
    @setEvalBranchQuota(2_000_000);
    comptime var out: []const u8 = "";
    inline for (entries) |e| {
        if (@hasDecl(e.zig, "VTable")) {
            out = out ++ checkVTable(c, e.zig, e.c);
        } else {
            out = out ++ checkStruct(c, e.zig, e.c);
        }
    }
    return out;
}

/// An entry for every public declaration of `M` that the headers could
/// declare: each interface (a struct with a `VTable`) and each other extern
/// struct, under its own name, less the names in `skip`. Listing a module
/// this way means a declaration added to it later is checked too.
pub fn entriesOf(comptime M: type, comptime skip: []const []const u8) []const Entry {
    @setEvalBranchQuota(200_000);
    comptime var out: []const Entry = &.{};
    decls: inline for (@typeInfo(M).@"struct".decl_names) |name| {
        inline for (skip) |s| if (comptime std.mem.eql(u8, s, name)) continue :decls;
        if (@TypeOf(@field(M, name)) != type) continue;
        const T = @field(M, name);
        if (@typeInfo(T) != .@"struct") continue;
        if (@typeInfo(T).@"struct".layout != .@"extern") continue;
        out = out ++ [_]Entry{.{ .zig = T, .c = name }};
    }
    return out;
}

/// A vtable slot: its name and its type.
const SlotInfo = struct {
    name: []const u8,
    T: type,
};

/// The slots of a vtable, its parents' first. A Zig vtable embeds its
/// parent's as a leading `base` field; a C one is already flat.
fn flatten(comptime V: type) []const SlotInfo {
    const info = @typeInfo(V).@"struct";
    comptime var out: []const SlotInfo = &.{};
    inline for (info.field_names, info.field_types) |name, T| {
        if (std.mem.eql(u8, name, "base") and @typeInfo(T) == .@"struct") {
            out = out ++ flatten(T);
        } else {
            out = out ++ [_]SlotInfo{.{ .name = name, .T = T }};
        }
    }
    return out;
}

fn checkVTable(comptime c: type, comptime Z: type, comptime c_name: []const u8) []const u8 {
    const vtbl_name = c_name ++ "Vtbl";
    if (!@hasDecl(c, vtbl_name)) return lineFor(Z, c_name, "the header has no " ++ vtbl_name);
    const zs = flatten(Z.VTable);
    const cs = flatten(@field(c, vtbl_name));
    comptime var out: []const u8 = "";
    if (zs.len != cs.len) out = out ++ lineFor(Z, c_name, std.fmt.comptimePrint(
        "{d} slots, the header has {d}",
        .{ zs.len, cs.len },
    ));

    // Over the slots both sides have, so that a dropped or added slot is
    // named by the first one it displaces.
    inline for (0..@min(zs.len, cs.len)) |i| {
        const z = zs[i];
        const h = cs[i];
        if (!sameSlotName(z.name, h.name)) {
            out = out ++ lineFor(Z, c_name, std.fmt.comptimePrint(
                "slot {d} is {s}, the header's is {s}",
                .{ i, z.name, h.name },
            ));
        } else if (z.T != *const anyopaque) {
            out = out ++ checkSlot(c, Z, c_name, z.name, z.T, h.T);
        }
    }
    return out;
}

/// Whether a Zig slot's name is the header's. Two habits of the headers
/// are allowed for: mingw prefixes an overloaded method's slot with its
/// interface (`IDWriteFactory1_CreateCustomRenderingParams`), and a method
/// that shares a Win32 function's name gets windows.h's ANSI rename
/// (`GetMessage` is `GetMessageA`), as the translation leaves UNICODE
/// undefined.
fn sameSlotName(comptime z: []const u8, comptime h: []const u8) bool {
    if (std.mem.eql(u8, z, h)) return true;
    if (h.len == z.len + 1 and std.mem.startsWith(u8, h, z) and h[z.len] == 'A') return true;
    if (h[0] == 'I') if (std.mem.indexOfScalar(u8, h, '_')) |i| return std.mem.eql(u8, h[i + 1 ..], z);
    return false;
}

/// The function type behind a slot: `*const fn` on the Zig side,
/// `?*const fn` in translate-c's.
fn slotFn(comptime T: type) ?std.lang.Type.Fn {
    const P = switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
    return switch (@typeInfo(P)) {
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |f| f,
            else => null,
        },
        else => null,
    };
}

fn checkSlot(
    comptime c: type,
    comptime Z: type,
    comptime c_name: []const u8,
    comptime slot: []const u8,
    comptime ZT: type,
    comptime CT: type,
) []const u8 {
    const zf = slotFn(ZT) orelse return lineFor(Z, c_name, slot ++ ": not a function pointer");
    const cf = slotFn(CT) orelse return lineFor(Z, c_name, slot ++ ": the header's is not a function pointer");
    if (zf.param_types.len != cf.param_types.len) return lineFor(Z, c_name, std.fmt.comptimePrint(
        "{s}: {d} parameters, the header has {d}",
        .{ slot, zf.param_types.len, cf.param_types.len },
    ));

    comptime var out: []const u8 = "";
    inline for (zf.param_types, cf.param_types, 0..) |zp, cp, i| {
        const zs = shape(c, zp.?);
        const cs = shape(c, cp.?);
        const same = if (i == 0)
            zs[0] == '*' and cs[0] == '*'
        else
            shapesMatch(zs, cs, false);
        if (!same) out = out ++ lineFor(Z, c_name, std.fmt.comptimePrint(
            "{s}: parameter {d} is {s}, the header's is {s}",
            .{ slot, i, zs, cs },
        ));
    }
    const zr = shape(c, zf.return_type.?);
    const cr = shape(c, cf.return_type.?);
    if (!shapesMatch(zr, cr, false)) out = out ++ lineFor(Z, c_name, std.fmt.comptimePrint(
        "{s}: returns {s}, the header's returns {s}",
        .{ slot, zr, cr },
    ));
    return out;
}

fn checkStruct(comptime c: type, comptime Z: type, comptime c_name: []const u8) []const u8 {
    if (!@hasDecl(c, c_name)) return lineFor(Z, c_name, "the header has no " ++ c_name);
    const C = @field(c, c_name);
    comptime var out: []const u8 = "";
    if (@sizeOf(Z) != @sizeOf(C) or @alignOf(Z) != @alignOf(C)) {
        out = out ++ lineFor(Z, c_name, std.fmt.comptimePrint(
            "size {d} align {d}, the header's size {d} align {d}",
            .{ @sizeOf(Z), @alignOf(Z), @sizeOf(C), @alignOf(C) },
        ));
    }
    const zi = @typeInfo(Z).@"struct";
    const ci = @typeInfo(C).@"struct";
    if (zi.field_names.len != ci.field_names.len) out = out ++ lineFor(Z, c_name, std.fmt.comptimePrint(
        "{d} fields, the header has {d}",
        .{ zi.field_names.len, ci.field_names.len },
    ));
    inline for (0..@min(zi.field_names.len, ci.field_names.len)) |i| {
        const zn = zi.field_names[i];
        const cn = ci.field_names[i];
        const anonymous = std.mem.startsWith(u8, cn, "unnamed_");
        if (!std.mem.eql(u8, zn, cn) and !anonymous) {
            out = out ++ lineFor(Z, c_name, "field " ++ zn ++ " stands where the header has " ++ cn);
        } else if (@offsetOf(Z, zn) != @offsetOf(C, cn) or
            @sizeOf(@FieldType(Z, zn)) != @sizeOf(@FieldType(C, cn)))
        {
            out = out ++ lineFor(Z, c_name, std.fmt.comptimePrint(
                "field {s} at {d} size {d}, the header's at {d} size {d}",
                .{ zn, @offsetOf(Z, zn), @sizeOf(@FieldType(Z, zn)), @offsetOf(C, cn), @sizeOf(@FieldType(C, cn)) },
            ));
        } else if (anonymous) {
            out = out ++ checkAnonymous(c, Z, c_name, zn, @FieldType(Z, zn), @FieldType(C, cn));
        } else {
            out = out ++ checkFieldType(c, Z, c_name, zn, @FieldType(Z, zn), @FieldType(C, cn));
        }
    }
    return out;
}

fn checkFieldType(
    comptime c: type,
    comptime Z: type,
    comptime c_name: []const u8,
    comptime field: []const u8,
    comptime ZT: type,
    comptime CT: type,
) []const u8 {
    const zs = shape(c, ZT);
    const cs = shape(c, CT);
    if (fieldShapesMatch(zs, cs)) return "";
    return lineFor(Z, c_name, "field " ++ field ++ " is " ++ zs ++ ", the header's is " ++ cs);
}

/// A field that stands on one of the header's anonymous unions, which
/// translate-c names `unnamed_N`. The Zig side either names the union and
/// declares some of its members (D3D11_RENDER_TARGET_VIEW_DESC's `u`), or
/// declares one member in its place (D3D11_BUFFER_SRV's FirstElement).
/// Either way each member it declares must be one of the union's, of the
/// same type. A member whose name starts with `_` only pads the union to
/// the header's size, which the caller has compared.
fn checkAnonymous(
    comptime c: type,
    comptime Z: type,
    comptime c_name: []const u8,
    comptime field: []const u8,
    comptime ZT: type,
    comptime CT: type,
) []const u8 {
    if (@typeInfo(CT) != .@"union") return lineFor(Z, c_name, "field " ++ field ++ " stands on an anonymous field that is not a union");
    const cu = @typeInfo(CT).@"union";
    const members: []const []const u8 = switch (@typeInfo(ZT)) {
        .@"union" => |u| u.field_names,
        else => &.{field},
    };
    comptime var out: []const u8 = "";
    inline for (members) |m| {
        if (comptime std.mem.startsWith(u8, m, "_")) continue;
        const MT = if (@typeInfo(ZT) == .@"union") @FieldType(ZT, m) else ZT;
        const label = if (@typeInfo(ZT) == .@"union") field ++ "." ++ m else field;
        const found = comptime for (cu.field_names) |n| {
            if (std.mem.eql(u8, n, m)) break true;
        } else false;
        if (!found) {
            out = out ++ lineFor(Z, c_name, "field " ++ label ++ " is not a member of the header's anonymous union");
        } else {
            out = out ++ checkFieldType(c, Z, c_name, label, MT, @FieldType(CT, m));
        }
    }
    return out;
}

/// Whether two shapes match: equal, except that an enum (`e32`) matches an
/// integer of its width (translate-c has no enum types, and makes some
/// unsigned), and that past a pointer, `void` matches anything. Pointer
/// levels must agree in number and constness.
fn shapesMatch(comptime a: []const u8, comptime b: []const u8, comptime pointee: bool) bool {
    if (std.mem.eql(u8, a, b)) return true;
    if (a[0] == '*' and b[0] == '*') {
        const ac = std.mem.startsWith(u8, a, "*const ");
        const bc = std.mem.startsWith(u8, b, "*const ");
        if (ac != bc) return false;
        const n = if (ac) "*const ".len else 1;
        return shapesMatch(a[n..], b[n..], true);
    }
    if (pointee and (std.mem.eql(u8, a, "void") or std.mem.eql(u8, b, "void"))) return true;
    if ((a[0] == 'e') != (b[0] == 'e') and
        std.mem.indexOfScalar(u8, "eiu", a[0]) != null and
        std.mem.indexOfScalar(u8, "eiu", b[0]) != null and
        isNumber(a[1..]) and std.mem.eql(u8, a[1..], b[1..])) return true;
    return false;
}

/// `shapesMatch` for a field: equal array lengths are peeled first, so
/// that an array of enums matches an array of integers.
fn fieldShapesMatch(comptime a: []const u8, comptime b: []const u8) bool {
    if (a[0] == '[' and b[0] == '[') {
        const ai = std.mem.indexOfScalar(u8, a, ']').?;
        const bi = std.mem.indexOfScalar(u8, b, ']').?;
        if (!std.mem.eql(u8, a[0..ai], b[0..bi])) return false;
        return fieldShapesMatch(a[ai + 1 ..], b[bi + 1 ..]);
    }
    return shapesMatch(a, b, false);
}

fn isNumber(comptime s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

/// A type as the check compares it: `void`, `i32`/`u32`/..., `e32` for an
/// enum, `f32`/`f64`, `fn`, a struct, union or opaque type's name (see
/// `typeName`), or `*` (and `const `) followed by the pointee's shape.
/// Optional, many-item and C pointers are all `*`, and a pointer to an
/// array is a pointer to its element, as a C array parameter is.
fn shape(comptime c: type, comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .void => "void",
        .bool => "bool",
        .int => |i| (if (i.signedness == .signed) "i" else "u") ++ std.fmt.comptimePrint("{d}", .{i.bits}),
        .float => |f| std.fmt.comptimePrint("f{d}", .{f.bits}),
        .@"enum" => |e| std.fmt.comptimePrint("e{d}", .{@typeInfo(e.tag_type).int.bits}),
        .optional => |o| shape(c, o.child),
        .pointer => |p| "*" ++ (if (p.attrs.@"const") "const " else "") ++ switch (@typeInfo(p.child)) {
            .@"fn" => "fn",
            .@"opaque" => if (p.child == anyopaque) "void" else typeName(c, p.child),
            .array => |a| shape(c, a.child),
            else => shape(c, p.child),
        },
        .@"struct", .@"union", .@"opaque" => typeName(c, T),
        .array => |a| std.fmt.comptimePrint("[{d}]", .{a.len}) ++ shape(c, a.child),
        else => @typeName(T),
    };
}

/// A container's name as the headers know it: its bare name, or, when the
/// headers declare that name as a typedef of another struct (dwrite's
/// `DWRITE_COLOR_F` is `D3DCOLORVALUE`), that struct's.
fn typeName(comptime c: type, comptime T: type) []const u8 {
    const name = bareName(T);
    if (@hasDecl(c, name) and @TypeOf(@field(c, name)) == type) {
        const C = @field(c, name);
        switch (@typeInfo(C)) {
            .@"struct", .@"union", .@"opaque" => return bareName(C),
            else => {},
        }
    }
    return name;
}

/// A container's name without its namespace, and with translate-c's
/// `struct_`/`union_` prefixes, mingw's leading `_` or `tag` and a handle's
/// trailing `__` dropped, so that `struct__GUID` and `std.os.windows.GUID`
/// are both `GUID`.
fn bareName(comptime T: type) []const u8 {
    const full = @typeName(T);
    var name: []const u8 = full;
    // A generic type's arguments may hold dots of their own.
    const head = std.mem.indexOfScalar(u8, full, '(') orelse full.len;
    if (std.mem.lastIndexOfScalar(u8, full[0..head], '.')) |i| name = full[i + 1 ..];
    for ([_][]const u8{ "struct_", "union_" }) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) name = name[prefix.len..];
    }
    if (std.mem.startsWith(u8, name, "_")) name = name[1..];
    if (std.mem.startsWith(u8, name, "tag")) name = name[3..];
    // A handle: std's `HWND` points at `HWND__opaque_N`, the headers' at
    // `HWND__`.
    if (std.mem.indexOf(u8, name, "__opaque_")) |i| name = name[0..i];
    if (std.mem.endsWith(u8, name, "__")) name = name[0 .. name.len - 2];
    return name;
}

fn lineFor(comptime Z: type, comptime c_name: []const u8, comptime msg: []const u8) []const u8 {
    return bareName(Z) ++ " (" ++ c_name ++ "): " ++ msg ++ "\n";
}

// The self tests check the checker on hand-made "C" declarations shaped as
// translate-c writes them, so they run on every host. Each seeded defect
// must produce a line; the faithful copy must produce none.

const cc: std.lang.CallingConvention = .c;

const FakeHeaders = struct {
    pub const struct_IThing = extern struct { lpVtbl: [*c]IThingVtbl = null };
    pub const IThing = struct_IThing;
    pub const struct_IOther = extern struct { lpVtbl: ?*anyopaque = null };
    pub const IOther = struct_IOther;
    pub const struct__THING_DESC = extern struct { Width: c_uint, Height: c_uint, Flags: u8 };
    pub const THING_DESC = struct__THING_DESC;
    pub const struct_IThingVtbl = extern struct {
        QueryInterface: ?*const fn ([*c]IThing, ?*const anyopaque, [*c]?*anyopaque) callconv(cc) i32 = null,
        AddRef: ?*const fn ([*c]IThing) callconv(cc) c_uint = null,
        Release: ?*const fn ([*c]IThing) callconv(cc) c_uint = null,
        Create: ?*const fn ([*c]IThing, [*c]const THING_DESC, [*c][*c]IOther) callconv(cc) i32 = null,
        GetCount: ?*const fn ([*c]IThing) callconv(cc) c_uint = null,
        SetMode: ?*const fn ([*c]IThing, c_int, c_uint) callconv(cc) void = null,
        Fill: ?*const fn ([*c]IThing, ?*anyopaque, usize) callconv(cc) i32 = null,
        // An overload, which mingw prefixes with the interface's name.
        IThing_Draw: ?*const fn ([*c]IThing, [*c]const f32, c_uint) callconv(cc) void = null,
        // windows.h's ANSI rename of a name it shares with a function.
        GetTextA: ?*const fn ([*c]IThing, [*c]LABEL) callconv(cc) i32 = null,
    };
    pub const IThingVtbl = struct_IThingVtbl;
    pub const struct__COLOR = extern struct { r: f32, g: f32 };
    pub const COLOR = struct__COLOR;
    /// A typedef of another struct, as dwrite's DWRITE_COLOR_F is.
    pub const LABEL = COLOR;
    pub const struct__VIEW = extern struct {
        Kind: c_uint,
        unnamed_0: extern union { a: c_uint, b: f32 },
    };
    pub const struct__RANGE = extern struct {
        unnamed_0: extern union { First: c_uint, Offset: c_uint },
        unnamed_1: extern union { Count: c_uint, Width: c_uint },
        Owner: [*c]IOther,
    };
    pub const RANGE = struct__RANGE;
    pub const VIEW = struct__VIEW;
};

/// The Zig side, faithful. The variants below each differ in one way.
fn ZigThing(comptime variant: enum {
    faithful,
    swapped,
    dropped,
    param_count,
    param_width,
    param_sign,
    wrong_pointee,
    wrong_interface,
    lost_const,
    returns,
    unicode_name,
    enum_width,
    array_element,
}) type {
    return extern struct {
        vtable: *const VTable,
        const Self = @This();
        const Slot = *const anyopaque;
        const Desc = if (variant == .wrong_pointee) WrongDesc else zig_side.THING_DESC;
        const Out = if (variant == .wrong_interface) zig_side.IWrong else zig_side.IOther;
        const DescPtr = if (variant == .lost_const) *Desc else *const Desc;
        const DrawFn = switch (variant) {
            .enum_width => *const fn (*Self, *const [4]f32, Mode16) callconv(cc) void,
            .array_element => *const fn (*Self, *const [4]f64, Mode) callconv(cc) void,
            else => *const fn (*Self, *const [4]f32, Mode) callconv(cc) void,
        };
        const TextFn = *const fn (*Self, *zig_side.LABEL) callconv(cc) i32;
        const Base = extern struct {
            QueryInterface: Slot,
            AddRef: Slot,
            Release: *const fn (*Self) callconv(cc) u32,
        };
        pub const VTable = switch (variant) {
            .swapped => extern struct {
                base: Base,
                Create: *const fn (*Self, DescPtr, *?*Out) callconv(cc) i32,
                SetMode: Slot,
                GetCount: Slot,
                Fill: Slot,
                Draw: Slot,
                GetText: Slot,
            },
            .unicode_name => extern struct {
                base: Base,
                Create: Slot,
                GetCount: Slot,
                SetMode: Slot,
                Fill: Slot,
                Draw: Slot,
                GetTextW: TextFn,
            },
            .dropped => extern struct {
                base: Base,
                Create: *const fn (*Self, DescPtr, *?*Out) callconv(cc) i32,
                GetCount: Slot,
                Fill: Slot,
                Draw: Slot,
                GetText: Slot,
            },
            else => extern struct {
                base: Base,
                Create: if (variant == .param_count)
                    *const fn (*Self, DescPtr) callconv(cc) i32
                else
                    *const fn (*Self, DescPtr, *?*Out) callconv(cc) i32,
                GetCount: if (variant == .returns)
                    *const fn (*Self) callconv(cc) u64
                else
                    *const fn (*Self) callconv(cc) u32,
                SetMode: switch (variant) {
                    .param_width => *const fn (*Self, i16, u32) callconv(cc) void,
                    .param_sign => *const fn (*Self, u32, u32) callconv(cc) void,
                    else => *const fn (*Self, Mode, u32) callconv(cc) void,
                },
                Fill: *const fn (*Self, *anyopaque, usize) callconv(cc) i32,
                Draw: DrawFn,
                GetText: TextFn,
            },
        };
    };
}

const Mode = enum(i32) { a, b };
const Mode16 = enum(i16) { a, b };
const WrongDesc = extern struct { Width: u32, Height: u32, Flags: u8 };
/// Types the Zig side points at, in their own namespace so that their
/// names can equal the fake header's.
const zig_side = struct {
    const THING_DESC = extern struct { Width: u32, Height: u32, Flags: u8 };
    const LABEL = extern struct { r: f32, g: f32 };
    const VIEW = extern struct { Kind: u32, u: extern union { a: u32, b: f32 } };
    const RANGE = extern struct { First: u32, Count: u32, Owner: ?*IOther };
    const IOther = opaque {};
    const IWrong = opaque {};
};

fn expectClean(comptime entries: []const Entry) !void {
    const found = comptime mismatches(FakeHeaders, entries);
    if (found.len != 0) {
        std.debug.print("unexpected mismatches:\n{s}", .{found});
        return error.TestUnexpectedResult;
    }
}

fn expectCaught(comptime entries: []const Entry, comptime needle: []const u8) !void {
    const found = comptime mismatches(FakeHeaders, entries);
    if (std.mem.indexOf(u8, found, needle) == null) {
        std.debug.print("expected a mismatch containing \"{s}\", got:\n{s}", .{ needle, found });
        return error.TestUnexpectedResult;
    }
}

test "com abi: a faithful vtable and struct have no mismatches" {
    try expectClean(&.{
        .{ .zig = ZigThing(.faithful), .c = "IThing" },
        .{ .zig = zig_side.THING_DESC, .c = "THING_DESC" },
        .{ .zig = zig_side.VIEW, .c = "VIEW" },
        .{ .zig = zig_side.RANGE, .c = "RANGE" },
    });
}

test "com abi: each seeded vtable defect is caught" {
    try expectCaught(&.{.{ .zig = ZigThing(.swapped), .c = "IThing" }}, "slot 4 is SetMode, the header's is GetCount");
    try expectCaught(&.{.{ .zig = ZigThing(.dropped), .c = "IThing" }}, "8 slots, the header has 9");
    try expectCaught(&.{.{ .zig = ZigThing(.dropped), .c = "IThing" }}, "slot 5 is Fill, the header's is SetMode");
    try expectCaught(&.{.{ .zig = ZigThing(.param_count), .c = "IThing" }}, "Create: 2 parameters, the header has 3");
    try expectCaught(&.{.{ .zig = ZigThing(.param_width), .c = "IThing" }}, "SetMode: parameter 1 is i16, the header's is i32");
    try expectCaught(&.{.{ .zig = ZigThing(.param_sign), .c = "IThing" }}, "SetMode: parameter 1 is u32, the header's is i32");
    try expectCaught(&.{.{ .zig = ZigThing(.wrong_pointee), .c = "IThing" }}, "Create: parameter 1 is *const WrongDesc, the header's is *const THING_DESC");
    try expectCaught(&.{.{ .zig = ZigThing(.wrong_interface), .c = "IThing" }}, "Create: parameter 2 is **IWrong, the header's is **IOther");
    try expectCaught(&.{.{ .zig = ZigThing(.lost_const), .c = "IThing" }}, "Create: parameter 1 is *THING_DESC, the header's is *const THING_DESC");
    try expectCaught(&.{.{ .zig = ZigThing(.returns), .c = "IThing" }}, "GetCount: returns u64, the header's returns u32");
    try expectCaught(&.{.{ .zig = ZigThing(.faithful), .c = "INone" }}, "the header has no INoneVtbl");
}

test "com abi: what the headers' habits allow stays narrow" {
    // Only the ANSI rename is allowed for, not the wide one.
    try expectCaught(&.{.{ .zig = ZigThing(.unicode_name), .c = "IThing" }}, "slot 8 is GetTextW, the header's is GetTextA");
    // An enum matches an integer of its own width only.
    try expectCaught(&.{.{ .zig = ZigThing(.enum_width), .c = "IThing" }}, "Draw: parameter 2 is e16, the header's is u32");
    // A pointer to an array is a pointer to its element, of its type.
    try expectCaught(&.{.{ .zig = ZigThing(.array_element), .c = "IThing" }}, "Draw: parameter 1 is *const f64, the header's is *const f32");
    // An anonymous union is compared by place and size.
    const WideView = extern struct { Kind: u32, u: extern union { a: u64, b: f32 } };
    try expectCaught(&.{.{ .zig = WideView, .c = "VIEW" }}, "field u at 8 size 8, the header's at 4 size 4");
}

test "com abi: each seeded struct defect is caught" {
    const Reordered = extern struct { Height: u32, Width: u32, Flags: u8 };
    const Wider = extern struct { Width: u32, Height: u64, Flags: u8 };
    const Shorter = extern struct { Width: u32, Height: u32 };
    try expectCaught(&.{.{ .zig = Reordered, .c = "THING_DESC" }}, "field Height stands where the header has Width");
    try expectCaught(&.{.{ .zig = Wider, .c = "THING_DESC" }}, "field Height at 8 size 8, the header's at 4 size 4");
    try expectCaught(&.{.{ .zig = Shorter, .c = "THING_DESC" }}, "2 fields, the header has 3");
    const NoHeight = extern struct { Width: u32, Flags: u8 };
    // Field types, not only sizes.
    const FloatWidth = extern struct { Width: f32, Height: u32, Flags: u8 };
    try expectCaught(&.{.{ .zig = FloatWidth, .c = "THING_DESC" }}, "field Width is f32, the header's is u32");
    const WrongOwner = extern struct { First: u32, Count: u32, Owner: ?*zig_side.IWrong };
    try expectCaught(&.{.{ .zig = WrongOwner, .c = "RANGE" }}, "field Owner is *IWrong, the header's is *IOther");
    // A member standing on an anonymous union must be one of its own.
    const Swapped = extern struct { Count: u32, First: u32, Owner: ?*zig_side.IOther };
    try expectCaught(&.{.{ .zig = Swapped, .c = "RANGE" }}, "field Count is not a member of the header's anonymous union");
    const WrongMember = extern struct { Kind: u32, u: extern union { a: u32, c: f32 } };
    try expectCaught(&.{.{ .zig = WrongMember, .c = "VIEW" }}, "field u.c is not a member of the header's anonymous union");
    const WrongMemberType = extern struct { Kind: u32, u: extern union { a: f32, b: f32 } };
    try expectCaught(&.{.{ .zig = WrongMemberType, .c = "VIEW" }}, "field u.a is f32, the header's is u32");
    try expectCaught(&.{.{ .zig = NoHeight, .c = "THING_DESC" }}, "field Flags stands where the header has Height");
}
