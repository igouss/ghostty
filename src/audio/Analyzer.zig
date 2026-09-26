//! Turns a stream of mono samples into the audio levels that custom
//! shaders see (see `Levels`). It keeps the most recent `fft_size`
//! samples and analyzes them with a Hann-windowed FFT.
//!
//! Every level is on a dB scale mapped to [0, 1], so quiet and loud
//! music look different; nothing is normalized per frame.
const Analyzer = @This();

const std = @import("std");
const math = std.math;

/// The rate we ask PipeWire to deliver samples at.
pub const sample_rate = 48000;

/// 2048 samples is ~43ms at 48kHz with ~23Hz frequency resolution.
pub const fft_size = 2048;

/// How many new samples to wait for before analyzing again (60Hz).
pub const hop_size = sample_rate / 60;

/// The width of one FFT bin in Hz.
const bin_hz: f32 = sample_rate / @as(f32, fft_size);

/// Number of spectrum bands, log spaced between `min_freq` and `max_freq`.
pub const bands = 128;
pub const min_freq = 30.0;
pub const max_freq = 16000.0;

/// Each band's upper frequency over its lower one.
const band_ratio = math.pow(f32, max_freq / min_freq, 1.0 / @as(f32, bands));

/// The dB ranges mapped to [0, 1]. Volume (RMS, peak) uses the full
/// range down to -60dBFS. A single frequency band holds much less energy
/// than the whole signal, so band levels use a range that sits lower.
const volume_floor_db = -60.0;
const band_floor_db = -70.0;
const band_ceil_db = -10.0;

/// Music loses energy toward the treble, so band levels are tilted up
/// by this much per octave above 1kHz (and down below it), as spectrum
/// analyzers commonly do, to make typical music read about level.
const tilt_db_per_octave = 4.5;

/// Levels fall by at most this much per second (attack is instant),
/// which keeps animations from flickering between analyses.
const release_per_s = 2.0;

pub const Levels = struct {
    rms: f32 = 0,
    peak: f32 = 0,
    bass: f32 = 0,
    mid: f32 = 0,
    treble: f32 = 0,
    /// In Hz, 0 when there is nothing to hear.
    dominant_freq: f32 = 0,
    spectrum: [bands]f32 = @splat(0),

    /// Move toward `target` over `dt` seconds: rises immediately and
    /// falls at `release_per_s`.
    pub fn approach(self: *Levels, target: *const Levels, dt: f32) void {
        const fall = @max(dt, 0) * release_per_s;
        inline for (.{ "rms", "peak", "bass", "mid", "treble" }) |name| {
            @field(self, name) = @max(@field(target, name), @field(self, name) - fall);
        }
        for (&self.spectrum, target.spectrum) |*v, t| v.* = @max(t, v.* - fall);
        self.dominant_freq = target.dominant_freq;
    }
};

/// The FFT bins each spectrum band covers. Low bands can be narrower
/// than one bin; those have `first > last` and interpolate at `center`.
const BandRange = struct { first: usize, last: usize, center: f32 };

history: [fft_size]f32 = @splat(0),
/// Where the next sample goes in `history`.
write_index: usize = 0,
/// Samples received since the last analysis.
pending: usize = 0,

window: [fft_size]f32,
twiddle_re: [fft_size / 2]f32,
twiddle_im: [fft_size / 2]f32,
band_ranges: [bands]BandRange,
/// Per-bin gain implementing `tilt_db_per_octave`.
tilt: [fft_size / 2]f32,

re: [fft_size]f32 = undefined,
im: [fft_size]f32 = undefined,
amp: [fft_size / 2]f32 = undefined,
/// `amp` with `tilt` applied, which band levels are measured from.
tilted: [fft_size / 2]f32 = undefined,

pub fn init(self: *Analyzer) void {
    self.* = .{
        .window = undefined,
        .twiddle_re = undefined,
        .twiddle_im = undefined,
        .band_ranges = undefined,
        .tilt = undefined,
    };

    const n: f32 = @floatFromInt(fft_size);
    for (&self.window, 0..) |*w, i| {
        const x: f32 = @floatFromInt(i);
        w.* = 0.5 - 0.5 * @cos(2 * math.pi * x / n);
    }
    for (&self.twiddle_re, &self.twiddle_im, 0..) |*tr, *ti, i| {
        const x: f32 = @floatFromInt(i);
        tr.* = @cos(-2 * math.pi * x / n);
        ti.* = @sin(-2 * math.pi * x / n);
    }

    for (&self.tilt, 0..) |*t, k| {
        const freq = @max(@as(f32, @floatFromInt(k)), 1) * bin_hz;
        t.* = math.pow(f32, 10, tilt_db_per_octave * @log2(freq / 1000) / 20);
    }

    for (&self.band_ranges, 0..) |*r, i| {
        const lo = min_freq * math.pow(f32, band_ratio, @floatFromInt(i));
        const hi = lo * band_ratio;
        r.* = .{
            .first = @intFromFloat(@ceil(lo / bin_hz)),
            .last = @intFromFloat(@floor(hi / bin_hz)),
            .center = @sqrt(lo * hi) / bin_hz,
        };
    }
}

/// Add new samples. Returns true once there are enough new samples
/// for `analyze` to be worth calling.
pub fn feed(self: *Analyzer, samples: []const f32) bool {
    for (samples) |s| {
        self.history[self.write_index] = s;
        self.write_index = (self.write_index + 1) % fft_size;
    }
    self.pending += samples.len;
    return self.pending >= hop_size;
}

/// Analyze the most recent `fft_size` samples.
pub fn analyze(self: *Analyzer) Levels {
    self.pending = 0;
    var result: Levels = .{};

    // Unroll the history oldest first, measuring volume on the way.
    var sum_sq: f32 = 0;
    var peak: f32 = 0;
    for (0..fft_size) |i| {
        const s = self.history[(self.write_index + i) % fft_size];
        sum_sq += s * s;
        peak = @max(peak, @abs(s));
        self.re[i] = s * self.window[i];
        self.im[i] = 0;
    }
    result.rms = mapDb(@sqrt(sum_sq / fft_size), volume_floor_db, 0);
    result.peak = mapDb(peak, volume_floor_db, 0);

    self.fft();

    // Scale so a full-scale sine reads 1.0 in its bin. The Hann window
    // sums to fft_size / 2 and a real sine splits into two bins.
    for (&self.amp, &self.tilted, self.tilt, 0..) |*a, *t, gain, k| {
        a.* = 4 * math.hypot(self.re[k], self.im[k]) / fft_size;
        t.* = a.* * gain;
    }

    result.bass = self.hzLevel(20, 250);
    result.mid = self.hzLevel(250, 2000);
    result.treble = self.hzLevel(2000, max_freq);
    result.dominant_freq = self.dominantFreq();

    // Bands sum their energy, so wider (higher) bands aren't penalized
    // for spreading it over more bins.
    for (&result.spectrum, self.band_ranges) |*out, r| {
        out.* = if (r.first <= r.last) self.binsLevel(r.first, r.last) else interp: {
            const k: usize = @intFromFloat(r.center);
            const t = r.center - @as(f32, @floatFromInt(k));
            break :interp bandDb(self.tilted[k] * (1 - t) + self.tilted[k + 1] * t);
        };
    }

    return result;
}

/// The level of everything between two frequencies.
fn hzLevel(self: *const Analyzer, lo_hz: f32, hi_hz: f32) f32 {
    return self.binsLevel(@intFromFloat(@ceil(lo_hz / bin_hz)), @intFromFloat(hi_hz / bin_hz));
}

/// The level of FFT bins `first` through `last`, as the amplitude of
/// a single sine with the same energy.
fn binsLevel(self: *const Analyzer, first: usize, last: usize) f32 {
    var energy: f32 = 0;
    for (self.tilted[first .. last + 1]) |a| energy += a * a;
    // A Hann-windowed sine spreads 1.5x its energy over its bins.
    return bandDb(@sqrt(energy / 1.5));
}

/// The loudest frequency, refined between bins by fitting a parabola
/// through the log magnitudes around the peak.
fn dominantFreq(self: *const Analyzer) f32 {
    var best: usize = 1;
    for (self.amp[1 .. self.amp.len - 1], 1..) |a, k| {
        if (a > self.amp[best]) best = k;
    }
    if (bandDb(self.amp[best]) <= 0) return 0;

    const l = @log(self.amp[best - 1] + 1e-12);
    const c = @log(self.amp[best] + 1e-12);
    const r = @log(self.amp[best + 1] + 1e-12);
    const denom = l - 2 * c + r;
    const offset = if (denom != 0) 0.5 * (l - r) / denom else 0;
    return (@as(f32, @floatFromInt(best)) + offset) * bin_hz;
}

/// In-place iterative radix-2 FFT of `re`/`im`.
fn fft(self: *Analyzer) void {
    const bits = math.log2_int(usize, fft_size);
    for (0..fft_size) |i| {
        const j = @bitReverse(@as(u32, @intCast(i))) >> @intCast(32 - bits);
        if (j > i) {
            std.mem.swap(f32, &self.re[i], &self.re[j]);
            std.mem.swap(f32, &self.im[i], &self.im[j]);
        }
    }

    var len: usize = 2;
    while (len <= fft_size) : (len *= 2) {
        const half = len / 2;
        const stride = fft_size / len;
        var start: usize = 0;
        while (start < fft_size) : (start += len) {
            for (0..half) |k| {
                const wr = self.twiddle_re[k * stride];
                const wi = self.twiddle_im[k * stride];
                const a = start + k;
                const b = a + half;
                const tr = self.re[b] * wr - self.im[b] * wi;
                const ti = self.re[b] * wi + self.im[b] * wr;
                self.re[b] = self.re[a] - tr;
                self.im[b] = self.im[a] - ti;
                self.re[a] += tr;
                self.im[a] += ti;
            }
        }
    }
}

/// Map a band amplitude to [0, 1].
fn bandDb(amp: f32) f32 {
    return mapDb(amp, band_floor_db, band_ceil_db);
}

/// Map an amplitude to [0, 1] on a dB scale between `floor_db` and `ceil_db`.
fn mapDb(amp: f32, floor_db: f32, ceil_db: f32) f32 {
    if (amp <= 0) return 0;
    const db = 20 * @log10(amp);
    return math.clamp((db - floor_db) / (ceil_db - floor_db), 0, 1);
}

fn feedSine(a: *Analyzer, freq: f32, amplitude: f32) void {
    var buf: [fft_size]f32 = undefined;
    for (&buf, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / sample_rate;
        s.* = amplitude * @sin(2 * math.pi * freq * t);
    }
    _ = a.feed(&buf);
}

test "fft matches a direct DFT" {
    const testing = std.testing;
    var a: Analyzer = undefined;
    a.init();

    var prng = std.Random.DefaultPrng.init(42);
    const rand = prng.random();
    var input: [fft_size]f32 = undefined;
    for (&input) |*v| v.* = rand.float(f32) * 2 - 1;
    a.re = input;
    a.im = @splat(0);
    a.fft();

    for ([_]usize{ 0, 1, 7, 100, 1023 }) |k| {
        var re: f64 = 0;
        var im: f64 = 0;
        for (input, 0..) |x, n| {
            const angle = -2 * math.pi * @as(f64, @floatFromInt(k * n)) / fft_size;
            re += x * @cos(angle);
            im += x * @sin(angle);
        }
        try testing.expectApproxEqAbs(re, a.re[k], 1e-2);
        try testing.expectApproxEqAbs(im, a.im[k], 1e-2);
    }
}

test "a full-scale sine" {
    const testing = std.testing;
    var a: Analyzer = undefined;
    a.init();

    feedSine(&a, 1000, 1);
    const levels = a.analyze();

    try testing.expectApproxEqAbs(1000, levels.dominant_freq, 5);
    // RMS of a sine is -3dB.
    try testing.expectApproxEqAbs(1 - 3.01 / 60.0, levels.rms, 0.01);
    try testing.expectApproxEqAbs(1, levels.peak, 0.01);
    try testing.expectEqual(1, levels.mid);
    try testing.expect(levels.bass < 0.3);
    try testing.expect(levels.treble < 0.3);

    // The loudest band is the one containing 1kHz.
    const band: usize = @intFromFloat(@log(1000.0 / min_freq) / @log(band_ratio));
    try testing.expectEqual(band, std.mem.indexOfMax(f32, &levels.spectrum));
}

test "quiet audio reads lower than loud audio" {
    const testing = std.testing;
    var a: Analyzer = undefined;
    a.init();

    feedSine(&a, 100, 1);
    const loud = a.analyze();
    feedSine(&a, 100, 0.01);
    const quiet = a.analyze();

    // -40dB is 40/60 of the volume range lower.
    try testing.expectApproxEqAbs(loud.rms - 40.0 / 60.0, quiet.rms, 0.01);
    try testing.expect(quiet.bass < loud.bass);
    try testing.expect(quiet.bass > 0);
}

test "silence" {
    const testing = std.testing;
    var a: Analyzer = undefined;
    a.init();

    _ = a.feed(&@as([fft_size]f32, @splat(0)));
    const levels = a.analyze();
    try testing.expectEqual(Levels{}, levels);
}

test "levels release gradually" {
    const testing = std.testing;
    var levels: Levels = .{ .rms = 1, .dominant_freq = 440 };
    levels.approach(&.{}, 0.25);
    try testing.expectApproxEqAbs(0.5, levels.rms, 1e-6);
    try testing.expectEqual(0, levels.dominant_freq);

    levels.approach(&.{ .rms = 0.9 }, 0.25);
    try testing.expectEqual(0.9, levels.rms);
}
