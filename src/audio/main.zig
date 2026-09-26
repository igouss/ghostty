//! System audio analysis for audio-reactive custom shaders.
pub const Analyzer = @import("Analyzer.zig");
pub const Capture = @import("Capture.zig");
pub const Levels = Analyzer.Levels;

test {
    @import("std").testing.refAllDecls(@This());
}
