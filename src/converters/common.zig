const std = @import("std");
const types = @import("types");

pub const Image = types.Image;
pub const Chroma = types.Chroma;
pub const Mask = types.Mask;

// =============================================================================
// Braille Constants
// =============================================================================

/// Braille dot positions for 2x4 grid (compile-time constant)
/// Maps each of 8 dots to their (x, y) position within the 2x4 Braille cell
pub const BRAILLE_DOT_POSITIONS = [8][2]u32{
    .{ 0, 0 }, // Dot 1 (bit 0x01)
    .{ 0, 1 }, // Dot 2 (bit 0x02)
    .{ 0, 2 }, // Dot 3 (bit 0x04)
    .{ 1, 0 }, // Dot 4 (bit 0x08)
    .{ 1, 1 }, // Dot 5 (bit 0x10)
    .{ 1, 2 }, // Dot 6 (bit 0x20)
    .{ 0, 3 }, // Dot 7 (bit 0x40)
    .{ 1, 3 }, // Dot 8 (bit 0x80)
};

/// Braille pattern bit positions layout:
/// 1 4   (0x01 0x08)
/// 2 5   (0x02 0x10)
/// 3 6   (0x04 0x20)
/// 7 8   (0x40 0x80)

// =============================================================================
// UTF-8 Encoding
// =============================================================================

/// Encode a Braille Unicode codepoint to UTF-8
/// Braille patterns (U+2800-U+28FF) always encode to 3 bytes
/// Inline for performance as this is called for every character
pub inline fn encodeUtf8Braille(codepoint: u21, buffer: []u8) usize {
    std.debug.assert(codepoint >= 0x2800 and codepoint <= 0x28FF);
    std.debug.assert(buffer.len >= 3);

    // UTF-8 encoding for 3-byte sequence (U+0800 to U+FFFF):
    // 1110xxxx 10xxxxxx 10xxxxxx
    buffer[0] = 0xE0 | @as(u8, @intCast((codepoint >> 12) & 0x0F));
    buffer[1] = 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3F));
    buffer[2] = 0x80 | @as(u8, @intCast(codepoint & 0x3F));

    return 3;
}

// =============================================================================
// Converter Interface
// =============================================================================

/// Generic converter interface for pluggable rendering backends
pub const Converter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        convert: *const fn (ptr: *anyopaque, image: Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) anyerror![]u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Convert image to text representation
    pub fn convert(self: Converter, image: Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) ![]u8 {
        return self.vtable.convert(self.ptr, image, target_cols, target_rows, allocator);
    }

    /// Clean up converter resources
    pub fn deinit(self: Converter) void {
        self.vtable.deinit(self.ptr);
    }
};

// =============================================================================
// Shared Utilities
// =============================================================================

/// Absolute difference between two u8 values
/// Uses branchless implementation for better performance in hot loops
pub inline fn absDiff(a: u8, b: u8) u32 {
    const diff: i32 = @as(i32, a) - @as(i32, b);
    return @abs(diff);
}

/// Clamp i32 to u8 range (0-255)
pub inline fn clampToU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

// =============================================================================
// Cell Shading (brightness / color / depth channels)
// =============================================================================

pub const Rgb = types.Rgb;
pub const Theme = types.Theme;

/// Optional per-cell coloring layered over the dot pattern. Cells are painted
/// only with the terminal's own colors: each cell picks the entry that best
/// completes what its dots show, and the difference is carried into the
/// neighbouring cells (error diffusion at cell resolution), so tones between
/// entries appear as mixtures. Without color only the neutral entries are
/// used; with color all of them.
///
/// - brightness: cell tone follows a tone curve of cell luma
/// - color: cell hue follows the source chroma
/// - depth: cell tone follows nearness (from the depth map): near cells get
///   full ink, far ones fade toward the background
pub const Shading = struct {
    brightness: bool,
    color: bool,
    depth: bool,
    theme: Theme,
    /// Tone curve: cell luma -> tone
    lut: [256]u8,
    /// Nearness -> tone (a straight ramp)
    depth_lut: [256]u8,

    /// Default curve exponent. The dither thresholds gamma-encoded luma, so a
    /// mid-gray region ends up ~50% dot coverage, which the eye reads as far
    /// brighter than the source meant. Lifting dot intensity by roughly
    /// Y'^(1.2/2.2) compensates; the density keeps carrying the tone.
    pub const default_gamma: f32 = 0.55;
    /// A lit dot never falls below this fraction of the way to the ink color
    pub const floor: u8 = 24;

    pub const none: Shading = .{
        .brightness = false,
        .color = false,
        .depth = false,
        .theme = undefined,
        .lut = undefined,
        .depth_lut = undefined,
    };

    pub const Options = struct {
        gamma: ?f32 = null,
        color: bool = false,
        /// Tone follows nearness: far cells sit near the background, near
        /// cells near the foreground
        depth: bool = false,
        theme: Theme,
    };

    pub fn init(options: Options) Shading {
        var s: Shading = .{
            .brightness = options.gamma != null,
            .color = options.color,
            .depth = options.depth,
            .theme = options.theme,
            .lut = undefined,
            .depth_lut = undefined,
        };
        if (options.gamma) |gamma| fillCurve(&s.lut, gamma);
        // Depth is a straight ramp: nearness 0 is the background, 255 the foreground
        for (0..256) |i| s.depth_lut[i] = @intCast(i);
        return s;
    }

    /// floor + (255 - floor) * x^exponent
    fn fillCurve(lut: *[256]u8, exponent: f32) void {
        const f: f32 = @floatFromInt(floor);
        for (0..256) |i| {
            const t = @as(f32, @floatFromInt(i)) / 255.0;
            const v = f + (255.0 - f) * std.math.pow(f32, t, exponent);
            lut[i] = @intFromFloat(@round(@min(255.0, @max(0.0, v))));
        }
    }

    /// Whether cells need color at encode time
    pub inline fn enabled(self: Shading) bool {
        return self.brightness or self.color or self.depth;
    }
};

/// Worst case bytes per shaded cell: "\x1b[22;107m" (9) + glyph (3)
const MAX_SHADED_CELL_BYTES = 12;
const RESET_SGR = "\x1b[0m";

/// Half-open source-pixel span covered by one output cell along one axis
const Span = struct { start: u32, end: u32 };

fn cellSpans(allocator: std.mem.Allocator, count: u32, pixels_per_cell: u32, scale: f32, limit: u32) ![]Span {
    const spans = try allocator.alloc(Span, count);
    for (spans, 0..) |*span, i| {
        const cell_start = @as(f32, @floatFromInt(i * pixels_per_cell)) * scale;
        const cell_end = @as(f32, @floatFromInt((i + 1) * pixels_per_cell)) * scale;
        var start: u32 = @intFromFloat(cell_start);
        var end: u32 = @intFromFloat(cell_end);
        if (start >= limit) start = limit - 1;
        if (end > limit) end = limit;
        if (end <= start) end = start + 1;
        span.* = .{ .start = start, .end = end };
    }
    return spans;
}

/// Mean luma over a cell footprint
fn cellLuma(image: Image, xs: Span, ys: Span) u8 {
    var sum: u32 = 0;
    for (ys.start..ys.end) |y| {
        const row = image.data[y * image.bytes_per_row ..];
        for (xs.start..xs.end) |x| {
            sum += row[x];
        }
    }
    const n = (ys.end - ys.start) * (xs.end - xs.start);
    return @intCast(sum / n);
}

/// The cell's actual color (mean luma and chroma over its footprint), or
/// null when there is no chroma to draw from
fn cellRgb(image: Image, luma: u8, xs: Span, ys: Span) ?Rgb {
    const chroma = image.chroma orelse return null;

    // Mean chroma over the footprint at 4:2:0 resolution
    const cx0 = @min(xs.start / 2, chroma.width - 1);
    const cx1 = @max(cx0 + 1, @min(xs.end / 2, chroma.width));
    const cy0 = @min(ys.start / 2, chroma.height - 1);
    const cy1 = @max(cy0 + 1, @min(ys.end / 2, chroma.height));
    var cb_sum: u32 = 0;
    var cr_sum: u32 = 0;
    for (cy0..cy1) |cy| {
        const row = chroma.data[cy * chroma.bytes_per_row ..];
        for (cx0..cx1) |cx| {
            cb_sum += row[cx * 2];
            cr_sum += row[cx * 2 + 1];
        }
    }
    const cn = (cy1 - cy0) * (cx1 - cx0);
    const cb: i32 = @as(i32, @intCast(cb_sum / cn)) - 128;
    const cr: i32 = @as(i32, @intCast(cr_sum / cn)) - 128;

    // Full-range BT.601 Y'CbCr -> RGB, fixed point (16 fractional bits)
    const yi: i32 = luma;
    return .{
        clampToU8(yi + ((91881 * cr) >> 16)),
        clampToU8(yi - ((22554 * cb + 46802 * cr) >> 16)),
        clampToU8(yi + ((116130 * cb) >> 16)),
    };
}

/// Mean nearness (0 far .. 255 near) over a cell footprint
fn cellNearness(image: Image, mask: types.Mask, xs: Span, ys: Span) u8 {
    var sum: u32 = 0;
    for (ys.start..ys.end) |y| {
        for (xs.start..xs.end) |x| {
            sum += mask.at(@intCast(x), @intCast(y), image.width, image.height);
        }
    }
    return @intCast(sum / ((ys.end - ys.start) * (xs.end - xs.start)));
}

/// What a cell asks of the palette: a hue (its color at full intensity) and
/// a tone (how much ink it should carry, 0-255). The dots already carry
/// luma, so the hue is brightness-free; tone comes from the brightness and
/// depth curves and only picks the normal or bright variant of an entry.
const CellLook = struct { hue: Rgb, level: u8 };

fn cellLook(image: Image, xs: Span, ys: Span, invert: bool, shading: Shading) CellLook {
    const luma = cellLuma(image, xs, ys);

    // In inverted output the ink marks dark regions, so tone follows inverted
    // luma to keep dense ink bright
    const tone: u8 = if (invert) 255 - luma else luma;
    var level: u32 = 255;
    if (shading.brightness) level = shading.lut[tone];
    if (shading.depth) {
        if (image.mask) |mask| {
            level = level * shading.depth_lut[cellNearness(image, mask, xs, ys)] / 255;
        }
    }

    var hue: Rgb = .{ 255, 255, 255 };
    if (shading.color) {
        if (cellRgb(image, luma, xs, ys)) |rgb| hue = normalizeHue(rgb);
    }
    return .{ .hue = hue, .level = @intCast(level) };
}

/// A color scaled so its brightest channel is full; neutral for black
fn normalizeHue(rgb: Rgb) Rgb {
    const max: u32 = @max(rgb[0], @max(rgb[1], rgb[2]));
    if (max == 0) return .{ 255, 255, 255 };
    return .{
        @intCast(@as(u32, rgb[0]) * 255 / max),
        @intCast(@as(u32, rgb[1]) * 255 / max),
        @intCast(@as(u32, rgb[2]) * 255 / max),
    };
}

// ---- palette -------------------------------------------------------------------

/// The theme foreground, as a candidate alongside the 16 palette entries
const fg_index: u8 = 16;

const Candidate = struct {
    rgb: Rgb,
    /// Entry at full intensity, what hue matching compares against
    hue: Rgb,
    /// Close enough to the background to read as "nothing"; only a tone
    /// target for fading out, never a hue
    near_bg: bool,
    /// Lies on the line from the background to the foreground: a genuine
    /// shade of the foreground (the foreground itself always qualifies)
    on_fg_line: bool,
    index: u8,
};

/// How far off the background-to-foreground line an entry may sit and still
/// count as a shade of the foreground. Tight on purpose: a palette rarely
/// contains true shades of its foreground, and anything that merely looks
/// gray-ish (a tinted gray, a tan) breaks the ramp. Tones between the
/// foreground and the background come from mixing the two across cells.
const shade_tolerance: u32 = 6;

/// Where `c` falls along the line from `from` to `to`, 0-255, and how far
/// off that line it is
fn projectOntoLine(c: Rgb, from: Rgb, to: Rgb) struct { t: u8, off: u32 } {
    var num: i64 = 0;
    var den: i64 = 0;
    for (0..3) |i| {
        const d: i64 = @as(i64, to[i]) - from[i];
        num += (@as(i64, c[i]) - from[i]) * d;
        den += d * d;
    }
    if (den == 0) return .{ .t = 0, .off = distanceSq(c, from) };
    const t_scaled = @max(0, @min(255, @divTrunc(num * 255, den)));
    var off: u32 = 0;
    for (0..3) |i| {
        const d: i64 = @as(i64, to[i]) - from[i];
        const point: i64 = from[i] + @divTrunc(d * t_scaled, 255);
        const diff: i64 = @as(i64, c[i]) - point;
        off += @intCast(diff * diff);
    }
    return .{ .t = @intCast(t_scaled), .off = off };
}

/// Every theme color a cell might be painted with (the 16 entries plus the
/// foreground). Hue matching skips the ones indistinguishable from the
/// background, and without color everything that is not a shade of the
/// foreground; tone matching walks whatever shades exist.
fn candidates(shading: Shading, out: *[17]Candidate) []Candidate {
    var all: [17]struct { rgb: Rgb, index: u8 } = undefined;
    for (shading.theme.colors, 0..) |c, i| all[i] = .{ .rgb = c, .index = @intCast(i) };
    all[16] = .{ .rgb = shading.theme.fg, .index = fg_index };
    for (all, 0..) |c, i| {
        const on_line = projectOntoLine(c.rgb, shading.theme.bg, shading.theme.fg);
        out[i] = .{
            .rgb = c.rgb,
            .hue = normalizeHue(c.rgb),
            .near_bg = distanceSq(c.rgb, shading.theme.bg) < 24 * 24,
            .on_fg_line = c.index == fg_index or on_line.off <= shade_tolerance * shade_tolerance,
            .index = c.index,
        };
    }
    return out[0..17];
}

inline fn hueEligible(c: Candidate, shading: Shading) bool {
    if (c.near_bg) return false;
    return shading.color or c.on_fg_line;
}

/// One rung of a tone ladder: a palette entry, possibly rendered dim
const Rung = struct { index: u8, dim: bool, t: u8 };

/// Where a color falls between the background and `top`, 0-255
fn toneOf(c: Rgb, bg: Rgb, top: Rgb) u8 {
    return projectOntoLine(c, bg, top).t;
}

/// Half way from the background to a color: what the terminal shows for
/// that color rendered dim, near enough
fn dimmed(c: Rgb, bg: Rgb) Rgb {
    var out: Rgb = undefined;
    for (0..3) |i| out[i] = @intCast((@as(u32, c[i]) + bg[i]) / 2);
    return out;
}

/// The rungs available for the hue that won, from nothing to full:
/// the entry nearest the background, then dim and normal (and bright, for
/// colors) renderings of the hue's entries. Only the foreground and true
/// shades of it serve the neutral ladder, so a fade never changes hue.
fn toneLadder(list: []const Candidate, pick: Candidate, shading: Shading, out: *[12]Rung) []Rung {
    const bg = shading.theme.bg;
    var n: usize = 0;

    // Bottom rung: whatever is closest to the background
    var floor_index: ?u8 = null;
    var floor_d: u32 = 24 * 24;
    for (list) |c| {
        const d = distanceSq(c.rgb, bg);
        if (d < floor_d) {
            floor_d = d;
            floor_index = c.index;
        }
    }
    if (floor_index) |idx| {
        out[n] = .{ .index = idx, .dim = false, .t = 0 };
        n += 1;
    }

    if (pick.on_fg_line) {
        const fg = shading.theme.fg;
        for (list) |c| {
            if (!c.on_fg_line or c.index == fg_index or c.near_bg) continue;
            if (n + 4 > out.len) break; // leave room for the foreground's two rungs
            out[n] = .{ .index = c.index, .dim = true, .t = toneOf(dimmed(c.rgb, bg), bg, fg) };
            n += 1;
            out[n] = .{ .index = c.index, .dim = false, .t = toneOf(c.rgb, bg, fg) };
            n += 1;
        }
        out[n] = .{ .index = fg_index, .dim = true, .t = 128 };
        n += 1;
        out[n] = .{ .index = fg_index, .dim = false, .t = 255 };
        n += 1;
        return out[0..n];
    }

    // A color: its normal and bright entries, measured against the brighter one
    const sibling: u8 = if (pick.index >= 8) pick.index - 8 else pick.index + 8;
    var family: [2]?Candidate = .{ pick, null };
    for (list) |c| {
        if (c.index == sibling) family[1] = c;
    }
    var top = pick.rgb;
    if (family[1]) |sib| {
        if (@max(sib.rgb[0], @max(sib.rgb[1], sib.rgb[2])) > @max(top[0], @max(top[1], top[2]))) top = sib.rgb;
    }
    for (family) |maybe| {
        const c = maybe orelse continue;
        out[n] = .{ .index = c.index, .dim = true, .t = toneOf(dimmed(c.rgb, bg), bg, top) };
        n += 1;
        out[n] = .{ .index = c.index, .dim = false, .t = toneOf(c.rgb, bg, top) };
        n += 1;
    }
    return out[0..n];
}

/// Threshold in [0, 1) for this cell: a fixed pseudo-random value per cell
/// (and per use, via `phase`), so mixing has no visible lattice and a
/// still cell never changes its mind between frames
inline fn orderedThreshold(col: u32, row: u32, phase: u32) f32 {
    var h: u32 = col *% 0x9E3779B1 ^ row *% 0x85EBCA77 ^ phase *% 0xC2B2AE3D;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    h *%= 0x297A2D39;
    h ^= h >> 15;
    return @as(f32, @floatFromInt(h >> 8)) / 16777216.0;
}

/// How far `want` sits from `a` toward `b`, 0-1, along the line between them
fn mixFraction(want: [3]i32, a: Rgb, b: Rgb) f32 {
    var num: i64 = 0;
    var den: i64 = 0;
    for (0..3) |i| {
        const d: i64 = @as(i64, b[i]) - a[i];
        num += (want[i] - a[i]) * d;
        den += d * d;
    }
    if (den == 0) return 0;
    return @max(0.0, @min(1.0, @as(f32, @floatFromInt(num)) / @as(f32, @floatFromInt(den))));
}

const NearestTwo = struct { first: Candidate, second: ?Candidate };

/// The two hue-eligible entries nearest `want`; the foreground wins ties
fn nearestTwo(list: []const Candidate, want: [3]i32, shading: Shading) NearestTwo {
    var first: ?Candidate = null;
    var first_d: i64 = std.math.maxInt(i64);
    var second: ?Candidate = null;
    var second_d: i64 = std.math.maxInt(i64);
    // Foreground first so ties keep it
    const fg = list[list.len - 1];
    if (hueEligible(fg, shading)) {
        first = fg;
        first_d = weightedDistance(want, fg.hue);
    }
    for (list) |c| {
        if (!hueEligible(c, shading) or c.index == fg_index) continue;
        const d = weightedDistance(want, c.hue);
        if (d < first_d) {
            first = c;
            first_d = d;
        }
    }
    const winner = first orelse fg;
    // Second: nearest entry of a genuinely different hue, else there is
    // nothing to mix with
    for (list) |c| {
        if (!hueEligible(c, shading) or std.meta.eql(c.hue, winner.hue)) continue;
        const d = weightedDistance(want, c.hue);
        if (d < second_d) {
            second = c;
            second_d = d;
        }
    }
    return .{ .first = winner, .second = second };
}

/// The rung for a tone: the two rungs around it, mixed by `threshold`
fn rungForTone(ladder: []const Rung, level: u8, threshold: f32) Rung {
    var lower: ?Rung = null;
    var upper: ?Rung = null;
    // Later rungs win ties: the ladder ends with the foreground's own rungs
    for (ladder) |r| {
        if (r.t <= level and (lower == null or r.t >= lower.?.t)) lower = r;
        if (r.t >= level and (upper == null or r.t <= upper.?.t)) upper = r;
    }
    const lo = lower orelse return upper.?;
    const hi = upper orelse return lo;
    if (hi.t == lo.t) return hi;
    const f = @as(f32, @floatFromInt(level - lo.t)) / @as(f32, @floatFromInt(hi.t - lo.t));
    return if (threshold < f) hi else lo;
}

inline fn distanceSq(a: Rgb, b: Rgb) u32 {
    var d: u32 = 0;
    for (0..3) |i| {
        const diff = absDiff(a[i], b[i]);
        d += diff * diff;
    }
    return d;
}

/// Perceptually weighted distance between a wanted hue and a candidate's
inline fn weightedDistance(want: [3]i32, c: Rgb) i64 {
    const dr: i64 = want[0] - c[0];
    const dg: i64 = want[1] - c[1];
    const db: i64 = want[2] - c[2];
    return 2 * dr * dr + 4 * dg * dg + 3 * db * db;
}

inline fn appendDecimal(out: *std.ArrayList(u8), v: u8) void {
    if (v >= 100) out.appendAssumeCapacity('0' + v / 100);
    if (v >= 10) out.appendAssumeCapacity('0' + (v / 10) % 10);
    out.appendAssumeCapacity('0' + v % 10);
}

/// Foreground SGR for a rung: intensity (dim or normal) plus the entry
/// (or the default foreground)
fn appendForeground(out: *std.ArrayList(u8), rung: Rung) void {
    out.appendSliceAssumeCapacity(if (rung.dim) "\x1b[2;" else "\x1b[22;");
    if (rung.index == fg_index) {
        appendDecimal(out, 39);
    } else {
        appendDecimal(out, if (rung.index < 8) 30 + rung.index else 90 + (rung.index - 8));
    }
    out.appendAssumeCapacity('m');
}

// ---- incremental re-dithering --------------------------------------------------

/// Pixels around a change that error diffusion must revisit. Kept smaller
/// than a Braille cell: neighbours carry their stored error across, so one
/// pixel of margin keeps the pattern continuous, and a patch this small
/// reads as dither noise rather than a rectangle.
pub const redo_margin: u32 = 1;
/// A changed pixel needs this many changed neighbours (of 8) to be
/// re-dithered. Zero: every change counts. Requiring agreement turns slow
/// drift into blobs that update together, which shows as blotches.
pub const redo_support: u8 = 0;

/// Turn a raw change map into the set of pixels to re-dither: drop isolated
/// changes (noise), then grow what is left by `redo_margin` in every
/// direction. Result has stride == width.
pub fn dilateChanged(changed: Mask, width: u32, height: u32, allocator: std.mem.Allocator) ![]u8 {
    const rows = try allocator.alloc(u8, width * height);
    defer allocator.free(rows);
    const out = try allocator.alloc(u8, width * height);
    errdefer allocator.free(out);

    // Support filter: keep a change only when its neighbourhood agrees
    for (0..height) |y| {
        const y0 = if (y > 0) y - 1 else y;
        const y1 = if (y + 1 < height) y + 1 else y;
        for (0..width) |x| {
            const dst = &out[y * width + x];
            dst.* = 0;
            if (changed.data[y * changed.bytes_per_row + x] == 0) continue;
            const x0 = if (x > 0) x - 1 else x;
            const x1 = if (x + 1 < width) x + 1 else x;
            var support: u8 = 0;
            for (y0..y1 + 1) |ny| {
                const row = changed.data[ny * changed.bytes_per_row ..];
                for (x0..x1 + 1) |nx| {
                    if ((nx != x or ny != y) and row[nx] != 0) support += 1;
                }
            }
            if (support >= redo_support) dst.* = 1;
        }
    }

    // Horizontal grow
    for (0..height) |y| {
        const src = out[y * width ..][0..width];
        const dst = rows[y * width ..][0..width];
        var run: u32 = 0;
        for (0..width) |x| {
            if (src[x] != 0) run = redo_margin + 1;
            dst[x] = if (run > 0) 1 else 0;
            if (run > 0) run -= 1;
        }
        var x: usize = width;
        run = 0;
        while (x > 0) {
            x -= 1;
            if (src[x] != 0) run = redo_margin + 1;
            if (run > 0) {
                dst[x] = 1;
                run -= 1;
            }
        }
    }
    // Vertical grow
    for (0..width) |x| {
        var run: u32 = 0;
        for (0..height) |y| {
            if (rows[y * width + x] != 0) run = redo_margin + 1;
            out[y * width + x] = if (run > 0) 1 else 0;
            if (run > 0) run -= 1;
        }
        var y: usize = height;
        run = 0;
        while (y > 0) {
            y -= 1;
            if (rows[y * width + x] != 0) run = redo_margin + 1;
            if (run > 0) {
                out[y * width + x] = 1;
                run -= 1;
            }
        }
    }
    return out;
}

// ---- encoder -----------------------------------------------------------------

/// Encode a grid of Braille cells to text.
/// `ctx` supplies the dot pattern per cell via `pattern(self, col, row) u8`.
/// With shading off this is the plain glyph grid; with shading on, colors are
/// emitted only when they change from the previous cell.
pub fn encodeBraille(
    ctx: anytype,
    image: Image,
    target_cols: u32,
    target_rows: u32,
    invert: bool,
    shading: Shading,
    allocator: std.mem.Allocator,
) ![]u8 {
    if (!shading.enabled()) return encodePlain(ctx, target_cols, target_rows, allocator);
    return encodeShaded(ctx, image, target_cols, target_rows, invert, shading, allocator);
}

fn encodePlain(ctx: anytype, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) ![]u8 {
    // Each Braille char is 3 bytes in UTF-8, plus newline per row
    const bytes_per_row = target_cols * 3 + 1;
    const total_bytes = target_rows * bytes_per_row;

    var buffer = try allocator.alloc(u8, total_bytes);
    var buf_offset: usize = 0;

    var row: u32 = 0;
    while (row < target_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < target_cols) : (col += 1) {
            const braille_char: u21 = 0x2800 + @as(u21, ctx.pattern(col, row));
            buf_offset += encodeUtf8Braille(braille_char, buffer[buf_offset..]);
        }

        buffer[buf_offset] = '\n';
        buf_offset += 1;
    }

    return buffer;
}

fn encodeShaded(
    ctx: anytype,
    image: Image,
    target_cols: u32,
    target_rows: u32,
    invert: bool,
    shading: Shading,
    allocator: std.mem.Allocator,
) ![]u8 {
    const scale_x = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(target_cols * 2));
    const scale_y = @as(f32, @floatFromInt(image.height)) / @as(f32, @floatFromInt(target_rows * 4));

    const col_spans = try cellSpans(allocator, target_cols, 2, scale_x, image.width);
    defer allocator.free(col_spans);
    const row_spans = try cellSpans(allocator, target_rows, 4, scale_y, image.height);
    defer allocator.free(row_spans);

    var candidate_storage: [17]Candidate = undefined;
    const palette = candidates(shading, &candidate_storage);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, target_rows * (target_cols * MAX_SHADED_CELL_BYTES + 1) + RESET_SGR.len);

    var prev_fg: ?Rung = null;

    var row: u32 = 0;
    while (row < target_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < target_cols) : (col += 1) {
            const pattern = ctx.pattern(col, row);

            // Blank cells show no ink and need no color
            if (pattern != 0) {
                const look = cellLook(image, col_spans[col], row_spans[row], invert, shading);

                // Hue: the two nearest entries, mixed by an ordered pattern
                // so tones between them appear as interleaved cells. Each
                // cell depends only on itself, so a still scene never
                // changes color.
                const want = [3]i32{ look.hue[0], look.hue[1], look.hue[2] };
                const pair = nearestTwo(palette, want, shading);
                const pick = if (pair.second) |second| blk: {
                    const f = mixFraction(want, pair.first.hue, second.hue);
                    break :blk if (orderedThreshold(col, row, 0) < f) second else pair.first;
                } else pair.first;

                // Tone: the two rungs around the wanted tone, mixed the same way
                var ladder_storage: [12]Rung = undefined;
                const ladder = toneLadder(palette, pick, shading, &ladder_storage);
                const rung = rungForTone(ladder, look.level, orderedThreshold(col, row, 1));

                if (prev_fg == null or prev_fg.?.index != rung.index or prev_fg.?.dim != rung.dim) {
                    appendForeground(&out, rung);
                    prev_fg = rung;
                }
            }

            var glyph: [3]u8 = undefined;
            _ = encodeUtf8Braille(0x2800 + @as(u21, pattern), &glyph);
            out.appendSliceAssumeCapacity(&glyph);
        }
        out.appendAssumeCapacity('\n');
    }
    out.appendSliceAssumeCapacity(RESET_SGR);

    return out.toOwnedSlice(allocator);
}

/// Samples a binary pixel buffer (stride == width) into Braille cells
const BinarySampler = struct {
    binary: []const u8,
    width: u32,
    height: u32,
    scale_x: f32,
    scale_y: f32,
    invert: bool,

    inline fn pattern(self: BinarySampler, col: u32, row: u32) u8 {
        var bits: u8 = 0;
        const base_out_x = col * 2;
        const base_out_y = row * 4;

        for (BRAILLE_DOT_POSITIONS, 0..) |pos, i| {
            const out_x = base_out_x + pos[0];
            const out_y = base_out_y + pos[1];

            const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_x)) * self.scale_x));
            const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_y)) * self.scale_y));

            if (src_x < self.width and src_y < self.height) {
                const idx = src_y * self.width + src_x;
                var is_set = self.binary[idx] != 0;
                if (self.invert) is_set = !is_set;
                if (is_set) {
                    bits |= @as(u8, 1) << @intCast(i);
                }
            }
        }
        return bits;
    }
};

/// Convert binary buffer to Braille text output
/// binary_data: image.width x image.height buffer where 0 = off, non-zero = on
/// Each Braille character represents a 2x4 pixel grid
pub fn binaryToBraille(
    binary_data: []const u8,
    image: Image,
    target_cols: u32,
    target_rows: u32,
    invert: bool,
    shading: Shading,
    allocator: std.mem.Allocator,
) ![]u8 {
    const sampler = BinarySampler{
        .binary = binary_data,
        .width = image.width,
        .height = image.height,
        .scale_x = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(target_cols * 2)),
        .scale_y = @as(f32, @floatFromInt(image.height)) / @as(f32, @floatFromInt(target_rows * 4)),
        .invert = invert,
    };
    return encodeBraille(sampler, image, target_cols, target_rows, invert, shading, allocator);
}

// =============================================================================
// Tests
// =============================================================================

test "Braille UTF-8 encoding" {
    var buffer: [3]u8 = undefined;

    // Empty pattern (all dots off)
    const bytes1 = encodeUtf8Braille(0x2800, &buffer);
    try std.testing.expectEqual(@as(usize, 3), bytes1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xE2, 0xA0, 0x80 }, buffer[0..]);

    // Full pattern (all dots on)
    const bytes2 = encodeUtf8Braille(0x28FF, &buffer);
    try std.testing.expectEqual(@as(usize, 3), bytes2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xE2, 0xA3, 0xBF }, buffer[0..]);
}

test "absDiff utility" {
    try std.testing.expectEqual(@as(u32, 10), absDiff(20, 10));
    try std.testing.expectEqual(@as(u32, 10), absDiff(10, 20));
    try std.testing.expectEqual(@as(u32, 0), absDiff(50, 50));
    try std.testing.expectEqual(@as(u32, 255), absDiff(255, 0));
}

test "clampToU8" {
    try std.testing.expectEqual(@as(u8, 0), clampToU8(-100));
    try std.testing.expectEqual(@as(u8, 0), clampToU8(0));
    try std.testing.expectEqual(@as(u8, 128), clampToU8(128));
    try std.testing.expectEqual(@as(u8, 255), clampToU8(255));
    try std.testing.expectEqual(@as(u8, 255), clampToU8(300));
}

const test_theme: Theme = .{
    .fg = .{ 255, 255, 255 },
    .bg = .{ 0, 0, 0 },
    .colors = .{
        .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
        .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
        .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
        .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
    },
};

test "Shading tone curve has floor, reaches white, is monotonic" {
    const s = Shading.init(.{ .gamma = Shading.default_gamma, .theme = test_theme });
    try std.testing.expectEqual(Shading.floor, s.lut[0]);
    try std.testing.expectEqual(@as(u8, 255), s.lut[255]);
    var prev: u8 = 0;
    for (s.lut) |v| {
        try std.testing.expect(v >= prev);
        prev = v;
    }
    // gamma < 1 lifts the midtones
    try std.testing.expect(s.lut[128] > 128);
}

fn fullImage(comptime w: u32, comptime h: u32, luma: u8) struct { data: [w * h]u8 } {
    return .{ .data = [_]u8{luma} ** (w * h) };
}

test "binaryToBraille without shading is the plain glyph grid" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 200);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{255} ** 64;

    const out = try binaryToBraille(&binary, image, 4, 2, false, .none, allocator);
    defer allocator.free(out);

    // 4 cols * 3 bytes + newline, 2 rows; every cell is U+28FF
    try std.testing.expectEqual(@as(usize, 26), out.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xE2, 0xA3, 0xBF }, out[0..3]);
    try std.testing.expectEqual(@as(u8, '\n'), out[12]);
}

test "brightness paints only neutral theme entries and mixes across cells" {
    const allocator = std.testing.allocator;
    // Left-to-right gradient, 16x8 pixels -> 8x2 cells
    var px: [16 * 8]u8 = undefined;
    for (0..8) |y| for (0..16) |x| {
        px[y * 16 + x] = @intCast(x * 17);
    };
    const image = Image{ .data = &px, .width = 16, .height = 8, .bytes_per_row = 16 };
    const binary = [_]u8{255} ** (16 * 8);

    const shading = Shading.init(.{ .gamma = 1.0, .theme = test_theme });
    const out = try binaryToBraille(&binary, image, 8, 2, false, shading, allocator);
    defer allocator.free(out);

    try std.testing.expect(std.mem.endsWith(u8, out, RESET_SGR));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b[38;"));
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b[48;"));
    // Only the foreground (dim or normal), true shades of it, and the
    // background-black rung: never a colored entry
    var it = std.mem.splitSequence(u8, out, "\x1b[");
    _ = it.next();
    while (it.next()) |chunk| {
        const m = std.mem.indexOfScalar(u8, chunk, 'm') orelse continue;
        const code = chunk[0..m];
        const ok = std.mem.eql(u8, code, "0") or std.mem.endsWith(u8, code, ";39") or std.mem.endsWith(u8, code, ";30") or std.mem.endsWith(u8, code, ";37") or std.mem.endsWith(u8, code, ";90") or std.mem.endsWith(u8, code, ";97");
        try std.testing.expect(ok);
    }
    // The gradient walks the ladder: normal-intensity rungs at the bright end,
    // dim or black rungs at the dark end
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[22;3") != null or std.mem.indexOf(u8, out, "\x1b[22;9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2;") != null or std.mem.indexOf(u8, out, ";30m") != null);
}

test "shaded blank cells emit no color" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 128);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{0} ** 64;

    const out = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .gamma = 0.55, .color = true, .theme = test_theme }), allocator);
    defer allocator.free(out);

    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b["));
    try std.testing.expect(std.mem.endsWith(u8, out, RESET_SGR));
}

fn redChromaImage(comptime w: u32, comptime h: u32, luma: u8, storage: *[w * h]u8, chroma: *[(w / 2) * (h / 2) * 2]u8) Image {
    @memset(storage, luma);
    for (0..(w / 2) * (h / 2)) |i| {
        chroma[i * 2] = 90; // Cb low
        chroma[i * 2 + 1] = 240; // Cr high: red
    }
    return .{
        .data = storage,
        .width = w,
        .height = h,
        .bytes_per_row = w,
        .chroma = .{ .data = chroma, .width = w / 2, .height = h / 2, .bytes_per_row = w },
    };
}

test "color paints a red scene with the theme's reds only" {
    const allocator = std.testing.allocator;
    var px: [16 * 8]u8 = undefined;
    var ch: [8 * 4 * 2]u8 = undefined;
    const image = redChromaImage(16, 8, 120, &px, &ch);
    const binary = [_]u8{255} ** (16 * 8);

    const out = try binaryToBraille(&binary, image, 8, 2, false, Shading.init(.{ .color = true, .theme = test_theme }), allocator);
    defer allocator.free(out);

    const reds = std.mem.count(u8, out, ";31m") + std.mem.count(u8, out, ";91m");
    try std.testing.expect(reds >= 1);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, ";32m") + std.mem.count(u8, out, ";34m") + std.mem.count(u8, out, ";92m") + std.mem.count(u8, out, ";94m"));
}

test "color mixes neighbouring cells to reach a tone between entries" {
    const allocator = std.testing.allocator;
    // Orange: between the theme's red (205,0,0) and yellow (205,205,0)
    var px: [32 * 8]u8 = undefined;
    var ch: [16 * 4 * 2]u8 = undefined;
    // Y'CbCr for roughly (230,120,0): luma ~143, Cb ~47, Cr ~190
    @memset(&px, 143);
    for (0..16 * 4) |i| {
        ch[i * 2] = 47;
        ch[i * 2 + 1] = 190;
    }
    const image = Image{ .data = &px, .width = 32, .height = 8, .bytes_per_row = 32, .chroma = .{ .data = &ch, .width = 16, .height = 4, .bytes_per_row = 32 } };
    const binary = [_]u8{255} ** (32 * 8);

    const out = try binaryToBraille(&binary, image, 16, 2, false, Shading.init(.{ .color = true, .theme = test_theme }), allocator);
    defer allocator.free(out);

    const reds = std.mem.count(u8, out, ";31m") + std.mem.count(u8, out, ";91m");
    const yellows = std.mem.count(u8, out, ";33m") + std.mem.count(u8, out, ";93m");
    try std.testing.expect(reds >= 1);
    try std.testing.expect(yellows >= 1);
}

test "color without chroma falls back to neutral entries" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 255);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{255} ** 64;

    const out = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .color = true, .theme = test_theme }), allocator);
    defer allocator.free(out);

    // White at full tone: the foreground itself
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[22;39m") != null);
}

test "dilateChanged grows changes by the margin" {
    const allocator = std.testing.allocator;
    var changed = [_]u8{0} ** (32 * 32);
    // A lone pixel: noise
    changed[3 * 32 + 3] = 1;
    // A 3x3 block: motion
    for (0..3) |dy| for (0..3) |dx| {
        changed[(16 + dy) * 32 + (16 + dx)] = 1;
    };
    const map: Mask = .{ .data = &changed, .width = 32, .height = 32, .bytes_per_row = 32 };
    const out = try dilateChanged(map, 32, 32, allocator);
    defer allocator.free(out);

    // The lone pixel counts too (no support required) and grows by the margin
    try std.testing.expectEqual(@as(u8, 1), out[3 * 32 + 3]);
    var count: usize = 0;
    for (out) |v| count += v;
    const side = 3 + redo_margin * 2;
    const lone = 1 + redo_margin * 2;
    try std.testing.expectEqual(@as(usize, side * side + lone * lone), count);
    try std.testing.expectEqual(@as(u8, 1), out[(16 - redo_margin) * 32 + (16 - redo_margin)]);
    try std.testing.expectEqual(@as(u8, 0), out[(16 - redo_margin - 1) * 32 + 17]);
}

test "depth fades far cells toward the background, near cells keep full ink" {
    const allocator = std.testing.allocator;
    const px = fullImage(16, 8, 200);
    // Left half near, right half far
    const mask_px = [_]u8{ 255, 255, 0, 0 };
    const image = Image{
        .data = &px.data,
        .width = 16,
        .height = 8,
        .bytes_per_row = 16,
        .mask = .{ .data = &mask_px, .width = 4, .height = 1, .bytes_per_row = 4 },
    };
    const binary = [_]u8{255} ** (16 * 8);

    const out = try binaryToBraille(&binary, image, 8, 2, false, Shading.init(.{ .depth = true, .theme = test_theme }), allocator);
    defer allocator.free(out);

    // Every dot still drawn
    try std.testing.expectEqual(@as(usize, 16), std.mem.count(u8, out, &[_]u8{ 0xE2, 0xA3, 0xBF }));
    // Near cells: the foreground itself; far cells: the entry closest to the
    // background (black, index 0)
    const first_row = out[0..std.mem.indexOfScalar(u8, out, '\n').?];
    try std.testing.expect(std.mem.startsWith(u8, first_row, "\x1b[22;39m"));
    try std.testing.expect(std.mem.indexOf(u8, first_row, "\x1b[22;30m") != null);
}
