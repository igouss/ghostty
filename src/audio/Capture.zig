//! Process-wide capture of what the default audio output is playing,
//! analyzed into `Levels` for audio-reactive custom shaders.
//!
//! There is one capture shared by every renderer that wants audio:
//! `acquire` starts it on first use and `release` stops it with the last
//! user. Analysis runs on PipeWire's loop thread; renderers only copy the
//! latest result, so a slow frame never stalls audio or vice versa.
const Capture = @This();

const std = @import("std");
const build_options = @import("build_options");
const global = @import("../global.zig");
const Analyzer = @import("Analyzer.zig");
const Levels = Analyzer.Levels;

const log = std.log.scoped(.audio);

/// Our PipeWire glue (pipewire.c).
const c = struct {
    const Handle = opaque {};
    const Callback = *const fn (?*anyopaque, [*]const f32, u32) callconv(.c) void;
    extern fn ghostty_audio_capture_new(rate: u32, cb: Callback, userdata: ?*anyopaque) ?*Handle;
    extern fn ghostty_audio_capture_free(?*Handle) void;
};

/// After this long without samples the output is idle (PipeWire stops
/// delivering when nothing plays), so we report silence.
const stale_ns = 100 * std.time.ns_per_ms;

/// Skip analysis when no renderer has read the levels for this long,
/// e.g. when no terminal is animating its shader.
const unread_ns = 250 * std.time.ns_per_ms;

/// Only touched by the PipeWire loop thread.
analyzer: Analyzer,

mutex: std.Io.Mutex = .init,
latest: Levels = .{},
latest_time: ?std.Io.Timestamp = null,
last_read: ?std.Io.Timestamp = null,

handle: ?*c.Handle = null,

var shared_mutex: std.Io.Mutex = .init;
var shared: ?*Capture = null;
var shared_refs: usize = 0;

/// Start (or share) the capture. Every successful call must be paired
/// with a `release`.
pub fn acquire() !*Capture {
    if (comptime !build_options.pipewire) return error.AudioUnsupported;

    shared_mutex.lockUncancelable(global.io());
    defer shared_mutex.unlock(global.io());

    if (shared) |self| {
        shared_refs += 1;
        return self;
    }

    const alloc = std.heap.c_allocator;
    const self = try alloc.create(Capture);
    errdefer alloc.destroy(self);
    self.* = .{ .analyzer = undefined };
    self.analyzer.init();

    self.handle = c.ghostty_audio_capture_new(Analyzer.sample_rate, onSamples, self) orelse
        return error.AudioCaptureFailed;
    log.info("audio capture started", .{});

    shared = self;
    shared_refs = 1;
    return self;
}

pub fn release(self: *Capture) void {
    shared_mutex.lockUncancelable(global.io());
    defer shared_mutex.unlock(global.io());

    std.debug.assert(shared == self);
    shared_refs -= 1;
    if (shared_refs > 0) return;

    // This joins the loop thread, so no callback can see `self` after.
    if (comptime build_options.pipewire) c.ghostty_audio_capture_free(self.handle);
    std.heap.c_allocator.destroy(self);
    shared = null;
    log.info("audio capture stopped", .{});
}

/// The most recent analysis, or silence if the output has gone idle.
pub fn read(self: *Capture) Levels {
    const now: std.Io.Timestamp = .now(global.io(), .awake);
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());

    self.last_read = now;
    const time = self.latest_time orelse return .{};
    if (time.durationTo(now).nanoseconds > stale_ns) return .{};
    return self.latest;
}

fn onSamples(userdata: ?*anyopaque, samples: [*]const f32, len: u32) callconv(.c) void {
    const self: *Capture = @ptrCast(@alignCast(userdata.?));
    if (!self.analyzer.feed(samples[0..len])) return;

    const now: std.Io.Timestamp = .now(global.io(), .awake);
    if (!self.isRead(now)) {
        self.analyzer.pending = 0;
        return;
    }

    const levels = self.analyzer.analyze();

    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    self.latest = levels;
    self.latest_time = now;
}

fn isRead(self: *Capture, now: std.Io.Timestamp) bool {
    self.mutex.lockUncancelable(global.io());
    defer self.mutex.unlock(global.io());
    const time = self.last_read orelse return false;
    return time.durationTo(now).nanoseconds < unread_ns;
}
