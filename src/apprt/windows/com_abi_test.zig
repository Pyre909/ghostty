//! Checks the Windows app's hand-written COM declarations against the
//! Windows SDK headers; `src/os/com_abi.zig` says how. The renderer's and
//! the font backend's are checked by their own api.zig.
//!
//! Every public interface and extern struct of the files below is checked,
//! so one added later is too. What is left out, and why:
//!
//!   - The Windows Runtime interfaces (toast.zig, and input_pane.zig's
//!     IInputPane2): their headers are not among those Zig ships.
const builtin = @import("builtin");

const com_abi = @import("../../os/com_abi.zig");

test "win32: COM declarations match the Windows headers" {
    if (comptime !builtin.target.isMinGW()) return error.SkipZigTest;
    const media = @import("media.zig");
    com_abi.expectMatch(com_abi.entriesOf(media, &.{"Notify"}) ++
        com_abi.entriesOf(@import("SaveDialog.zig"), &.{}) ++
        com_abi.entriesOf(@import("taskbar.zig"), &.{}) ++
        com_abi.entriesOf(@import("input_pane.zig"), &.{}) ++
        &[_]com_abi.Entry{
            // The bell's own implementation of the engine's callback.
            .{ .zig = media.Notify, .c = "IMFMediaEngineNotify" },
        });
}
