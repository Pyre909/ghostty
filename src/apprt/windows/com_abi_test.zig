//! Checks the Windows code's hand-written COM declarations against the
//! Windows SDK headers; `src/os/com_abi.zig` says how. A mismatch fails the
//! Windows test build itself, naming each slot or field that differs, so it
//! shows on a cross-compile without running anything on Windows.
//!
//! Every public interface and extern struct of the files below is checked,
//! so one added later is too. What is left out, and why:
//!
//!   - DirectComposition's interfaces: dcomp.h declares them for C++ only,
//!     so there is no C vtable to compare with.
//!   - The Windows Runtime interfaces (toast.zig, and input_pane.zig's
//!     IInputPane2): their headers are not among those Zig ships.
const std = @import("std");
const builtin = @import("builtin");

const com_abi = @import("../../os/com_abi.zig");

test "win32: COM declarations match the Windows headers" {
    if (comptime !builtin.target.isMinGW()) return error.SkipZigTest;
    comptime {
        const found = com_abi.mismatches(@import("windows-com-h"), entries());
        if (found.len != 0) @compileError("COM declarations differ from the headers:\n" ++ found);
    }
}

fn entries() []const com_abi.Entry {
    const d3d11 = @import("../../renderer/d3d11/api.zig");
    const dwrite = @import("../../font/directwrite/api.zig");
    const media = @import("media.zig");
    return com_abi.entriesOf(d3d11, &.{
        // d3dcommon.h names the interface ID3D10Blob; ID3DBlob is its
        // typedef.
        "ID3DBlob",
        "IDCompositionDevice",
        "IDCompositionTarget",
        "IDCompositionVisual",
    }) ++ com_abi.entriesOf(dwrite, &.{}) ++
        com_abi.entriesOf(media, &.{"Notify"}) ++
        com_abi.entriesOf(@import("SaveDialog.zig"), &.{}) ++
        com_abi.entriesOf(@import("taskbar.zig"), &.{}) ++
        com_abi.entriesOf(@import("input_pane.zig"), &.{}) ++
        &[_]com_abi.Entry{
            .{ .zig = d3d11.ID3DBlob, .c = "ID3D10Blob" },
            // The bell's own implementation of the engine's callback.
            .{ .zig = media.Notify, .c = "IMFMediaEngineNotify" },
        };
}
