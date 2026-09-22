const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const c = b.addTranslateC(.{
        .root_source_file = b.path("gl.c"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(b.path("../../vendor/glad/include"));

    // Zig passes -D_FORTIFY_SOURCE=2 to translate-c in ReleaseSafe, and
    // mingw's fortified string wrappers then reach the translation in a form
    // translate-c cannot express (__builtin_object_size with a bool argument,
    // unused extern locals), so the unit does not build. The wrappers are
    // inline conveniences for C callers that the Zig side never calls.
    if (target.result.os.tag == .windows) c.defineCMacro("_FORTIFY_SOURCE", "0");

    const module = b.addModule("opengl", .{ .root_source_file = b.path("main.zig") });
    module.addImport("c", c.createModule());
}
