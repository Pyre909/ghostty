const std = @import("std");
const c = @import("hb_c");
const Blob = @import("blob.zig").Blob;
const Error = @import("errors.zig").Error;

/// A font face is an object that represents a single face from within a font family.
///
/// More precisely, a font face represents a single face in a binary font file.
/// Font faces are typically built from a binary blob and a face index.
/// Font faces are used to create fonts.
pub const Face = struct {
    handle: *c.hb_face_t,

    /// Variant of hb_face_create(), built for those cases where it is more
    /// convenient to provide data for individual tables instead of the whole
    /// font data. With the caveat that hb_face_get_table_tags() would not
    /// work with faces created this way.
    ///
    /// Creates a new face object from the specified user_data and func,
    /// with the destroycb callback. The function is called with the tag of
    /// a table (an hb_tag_t, the first character in the high byte) each time
    /// HarfBuzz needs one, and returns a blob the face takes ownership of,
    /// or null if the table is not found or cannot be referenced.
    ///
    /// The face owns user_data from the moment of the call: when this
    /// fails the callback has already been called, so the caller must not
    /// release user_data again.
    pub fn createForTables(
        comptime T: type,
        comptime func: fn (face: Face, tag: u32, user_data: ?*T) ?Blob,
        user_data: ?*T,
        comptime destroycb: ?*const fn (?*T) callconv(.c) void,
    ) Error!Face {
        const Callback = struct {
            pub fn referenceTable(
                face: ?*c.hb_face_t,
                tag: c.hb_tag_t,
                ptr: ?*anyopaque,
            ) callconv(.c) ?*c.hb_blob_t {
                const blob = @call(.always_inline, func, .{
                    Face{ .handle = face.? },
                    tag,
                    @as(?*T, @ptrCast(@alignCast(ptr))),
                }) orelse return null;
                return blob.handle;
            }

            pub fn destroy(ptr: ?*anyopaque) callconv(.c) void {
                @call(.always_inline, destroycb.?, .{
                    @as(?*T, @ptrCast(@alignCast(ptr))),
                });
            }
        };

        // HarfBuzz never returns null here. A failure returns the empty
        // face singleton, after calling the destroy callback.
        const handle = c.hb_face_create_for_tables(
            Callback.referenceTable,
            user_data,
            if (destroycb != null) Callback.destroy else null,
        ) orelse return Error.HarfbuzzFailed;
        if (handle == c.hb_face_get_empty()) return Error.HarfbuzzFailed;

        return Face{ .handle = handle };
    }

    /// Decreases the reference count on a face object. When the reference
    /// count reaches zero, the face is destroyed, freeing all memory.
    pub fn destroy(self: *Face) void {
        c.hb_face_destroy(self.handle);
    }

    /// Assigns the specified face-index to face. Fails if the face
    /// is immutable.
    ///
    /// Note: changing the index has no effect on the face itself. This only
    /// changes the value returned by getIndex.
    pub fn setIndex(self: *Face, index: u32) void {
        c.hb_face_set_index(self.handle, @intCast(index));
    }

    /// Fetches the face-index corresponding to the given face.
    ///
    /// Note: face indices within a collection are zero-based.
    pub fn getIndex(self: Face) u32 {
        return @intCast(c.hb_face_get_index(self.handle));
    }

    /// Sets the units-per-em (upem) for a face object to the specified value.
    ///
    /// This API is used in rare circumstances.
    pub fn setUpem(self: *Face, upem: u32) void {
        c.hb_face_set_upem(self.handle, @intCast(upem));
    }

    /// Fetches the units-per-em (UPEM) value of the specified face object.
    ///
    /// Typical UPEM values for fonts are 1000, or 2048, but any value in
    /// between 16 and 16,384 is allowed for OpenType fonts.
    pub fn getUpem(self: Face) u32 {
        return @intCast(c.hb_face_get_upem(self.handle));
    }

    /// Sets the glyph count for a face object to the specified value.
    ///
    /// This API is used in rare circumstances.
    pub fn setGlyphCount(self: *Face, glyph_count: u32) void {
        c.hb_face_set_glyph_count(self.handle, @intCast(glyph_count));
    }

    /// Fetches the glyph-count value of the specified face object.
    pub fn getGlyphCount(self: Face) u32 {
        return @intCast(c.hb_face_get_glyph_count(self.handle));
    }
};

test "create for tables" {
    const testing = std.testing;

    const State = struct {
        const Self = @This();

        const table = "hello";

        requested: u32 = 0,
        tables_destroyed: usize = 0,
        destroyed: bool = false,

        fn referenceTable(_: Face, tag: u32, self_: ?*Self) ?Blob {
            const self = self_.?;
            self.requested = tag;
            if (tag != std.mem.readInt(u32, "test", .big)) return null;
            return Blob.createWithDestroy(
                Self,
                table,
                .readonly,
                self,
                destroyTable,
            ) catch null;
        }

        fn destroyTable(self: ?*Self) callconv(.c) void {
            self.?.tables_destroyed += 1;
        }

        fn destroy(self: ?*Self) callconv(.c) void {
            self.?.destroyed = true;
        }
    };

    var state: State = .{};
    var face = try Face.createForTables(
        State,
        State.referenceTable,
        &state,
        State.destroy,
    );
    {
        errdefer face.destroy();

        face.setIndex(3);
        try testing.expectEqual(@as(u32, 3), face.getIndex());
        face.setUpem(2048);
        try testing.expectEqual(@as(u32, 2048), face.getUpem());
        face.setGlyphCount(42);
        try testing.expectEqual(@as(u32, 42), face.getGlyphCount());

        // A table the callback has.
        const tag = std.mem.readInt(u32, "test", .big);
        const found = c.hb_face_reference_table(face.handle, tag);
        try testing.expectEqual(tag, state.requested);
        try testing.expectEqual(
            @as(c_uint, State.table.len),
            c.hb_blob_get_length(found),
        );
        c.hb_blob_destroy(found);
        try testing.expectEqual(@as(usize, 1), state.tables_destroyed);

        // A table it doesn't have is the empty blob.
        const missing = c.hb_face_reference_table(
            face.handle,
            std.mem.readInt(u32, "none", .big),
        );
        try testing.expectEqual(@as(c_uint, 0), c.hb_blob_get_length(missing));
        c.hb_blob_destroy(missing);
        try testing.expectEqual(@as(usize, 1), state.tables_destroyed);
    }

    try testing.expect(!state.destroyed);
    face.destroy();
    try testing.expect(state.destroyed);
}
