const std = @import("std");
const c = @import("hb_c");
const Blob = @import("blob.zig").Blob;
const Face = @import("face.zig").Face;
const Variation = @import("common.zig").Variation;
const Error = @import("errors.zig").Error;

pub const Font = struct {
    handle: *c.hb_font_t,

    /// Constructs a new font object from the specified face.
    pub fn create(face: Face) Error!Font {
        const handle = c.hb_font_create(face.handle) orelse return Error.HarfbuzzFailed;
        return Font{ .handle = handle };
    }

    /// Decreases the reference count on the given font object. When the
    /// reference count reaches zero, the font is destroyed, freeing all memory.
    pub fn destroy(self: *Font) void {
        c.hb_font_destroy(self.handle);
    }

    pub fn setScale(self: *Font, x: u32, y: u32) void {
        c.hb_font_set_scale(
            self.handle,
            @intCast(x),
            @intCast(y),
        );
    }

    /// Applies a list of font-variation settings to a font.
    ///
    /// Note that this overrides all existing variations set on font. Axes
    /// not included in variations will be effectively set to their
    /// default values.
    pub fn setVariations(self: *Font, variations: []const Variation) void {
        c.hb_font_set_variations(
            self.handle,
            @ptrCast(variations.ptr),
            @intCast(variations.len),
        );
    }
};

test "set variations" {
    const testing = std.testing;

    // A face whose only table is an fvar with two axes: wght from 100 to
    // 900 with a default of 400, and wdth from 50 to 200 with a default
    // of 100.
    const Tables = struct {
        const fvar = [_]u8{
            0x00, 0x01, 0x00, 0x00, // version 1.0
            0x00, 0x10, // axesArrayOffset
            0x00, 0x02, // reserved
            0x00, 0x02, // axisCount
            0x00, 0x14, // axisSize
            0x00, 0x00, // instanceCount
            0x00, 0x0c, // instanceSize
            'w',  'g',
            'h',  't',
            0x00, 0x64, 0x00, 0x00, // minValue, 16.16
            0x01, 0x90, 0x00, 0x00, // defaultValue
            0x03, 0x84, 0x00, 0x00, // maxValue
            0x00, 0x00, // flags
            0x01, 0x00, // axisNameID
            'w',  'd',
            't',  'h',
            0x00, 0x32, 0x00, 0x00, // minValue
            0x00, 0x64, 0x00, 0x00, // defaultValue
            0x00, 0xc8, 0x00, 0x00, // maxValue
            0x00, 0x00, // flags
            0x01, 0x01, // axisNameID
        };

        fn referenceTable(_: Face, tag: u32, _: ?*anyopaque) ?Blob {
            if (tag != std.mem.readInt(u32, "fvar", .big)) return null;
            return Blob.create(&fvar, .readonly) catch null;
        }
    };

    var face = try Face.createForTables(
        anyopaque,
        Tables.referenceTable,
        null,
        null,
    );
    defer face.destroy();

    var font = try Font.create(face);
    defer font.destroy();

    var len: c_uint = 0;
    font.setVariations(&.{
        .{ .tag = std.mem.readInt(u32, "wght", .big), .value = 700 },
    });
    var coords = c.hb_font_get_var_coords_design(font.handle, &len);
    try testing.expectEqual(@as(c_uint, 2), len);
    try testing.expectEqual(@as(f32, 700), coords[0]);
    try testing.expectEqual(@as(f32, 100), coords[1]);

    // The variations that are set are all there are: an axis that is
    // not among them is back on its default.
    font.setVariations(&.{
        .{ .tag = std.mem.readInt(u32, "wdth", .big), .value = 150 },
    });
    coords = c.hb_font_get_var_coords_design(font.handle, &len);
    try testing.expectEqual(@as(c_uint, 2), len);
    try testing.expectEqual(@as(f32, 400), coords[0]);
    try testing.expectEqual(@as(f32, 150), coords[1]);
}
