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
pub const Palette = types.Palette;
pub const Theme = types.Theme;

/// Optional per-cell coloring layered over the dot pattern. All ranges run
/// from the terminal's background to its foreground (or to the source's hue
/// when color is on), so output follows the user's theme.
///
/// - brightness: dot intensity follows a tone curve of cell luma
/// - color: dot hue follows the source chroma
/// - depth: only the nearest part of the scene (from the camera's person
///   mask) is dithered; the rest stays empty so the terminal shows through
pub const Shading = struct {
    brightness: bool,
    color: bool,
    /// How far into the scene to keep: 0 = only what the mask is surest is
    /// nearest, 255 = everything
    depth: ?u8,
    palette: Palette,
    theme: Theme,
    /// Tone curve: cell luma -> mix amount toward the ink color
    lut: [256]u8,

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
        .depth = null,
        .palette = .truecolor,
        .theme = undefined,
        .lut = undefined,
    };

    pub const Options = struct {
        gamma: ?f32 = null,
        color: bool = false,
        depth: ?u8 = null,
        palette: Palette = .@"256",
        theme: Theme,
    };

    pub fn init(options: Options) Shading {
        var s: Shading = .{
            .brightness = options.gamma != null,
            .color = options.color,
            .depth = options.depth,
            .palette = options.palette,
            .theme = options.theme,
            .lut = undefined,
        };
        if (options.gamma) |gamma| {
            const f: f32 = @floatFromInt(floor);
            for (0..256) |i| {
                const t = @as(f32, @floatFromInt(i)) / 255.0;
                const v = f + (255.0 - f) * std.math.pow(f32, t, gamma);
                s.lut[i] = @intFromFloat(@round(@min(255.0, @max(0.0, v))));
            }
        }
        return s;
    }

    /// Whether cells need color at encode time (depth alone does not)
    pub inline fn enabled(self: Shading) bool {
        return self.brightness or self.color;
    }
};

/// Worst case bytes per shaded cell: truecolor fg escape (19) + glyph (3)
const MAX_SHADED_CELL_BYTES = 22;
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

/// The source's hue at full intensity over a cell footprint, or null when
/// there is no chroma to draw from
fn cellHue(image: Image, luma: u8, xs: Span, ys: Span) ?Rgb {
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
    const r: u32 = clampToU8(yi + ((91881 * cr) >> 16));
    const g: u32 = clampToU8(yi - ((22554 * cb + 46802 * cr) >> 16));
    const b: u32 = clampToU8(yi + ((116130 * cb) >> 16));

    // Normalize so the brightest channel is full: hue and saturation only
    const m = @max(r, @max(g, b));
    if (m == 0) return null;
    return .{ @intCast(r * 255 / m), @intCast(g * 255 / m), @intCast(b * 255 / m) };
}

/// Linear blend from `a` toward `b` by t/255
inline fn mix(a: Rgb, b: Rgb, t: u32) Rgb {
    var out: Rgb = undefined;
    for (0..3) |i| {
        const ai: u32 = a[i];
        const bi: u32 = b[i];
        out[i] = @intCast((ai * (255 - t) + bi * t) / 255);
    }
    return out;
}

/// Dot color for one cell
fn cellShade(image: Image, xs: Span, ys: Span, invert: bool, shading: Shading) Rgb {
    const luma = cellLuma(image, xs, ys);

    // In inverted output the ink marks dark regions, so tone follows inverted
    // luma to keep dense ink bright
    const tone: u8 = if (invert) 255 - luma else luma;
    const t: u32 = if (shading.brightness) shading.lut[tone] else 255;

    const ink: Rgb = if (shading.color) (cellHue(image, luma, xs, ys) orelse shading.theme.fg) else shading.theme.fg;
    return mix(shading.theme.bg, ink, t);
}

// ---- palette mapping ---------------------------------------------------------

/// A color as it will be sent to the terminal; equal values mean no new escape
const Encoded = union(enum) {
    rgb: Rgb,
    index: u8,
};

inline fn quantize(v: u8) u8 {
    // 32 levels per channel: long runs of identical color mean far fewer
    // escape sequences on the wire, invisible at dot scale
    return (v & 0xF8) | 0x04;
}

const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

inline fn nearestCubeLevel(v: u8) u8 {
    var best: u8 = 0;
    var best_d: u32 = 256;
    for (cube_levels, 0..) |level, i| {
        const d = absDiff(v, level);
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return best;
}

inline fn distanceSq(a: Rgb, b: Rgb) u32 {
    var d: u32 = 0;
    for (0..3) |i| {
        const diff = absDiff(a[i], b[i]);
        d += diff * diff;
    }
    return d;
}

/// Nearest entry of the xterm 256-color palette: the 6x6x6 cube or, for
/// near-neutral colors, the finer 24-step gray ramp
pub fn nearest256(rgb: Rgb) u8 {
    const ri = nearestCubeLevel(rgb[0]);
    const gi = nearestCubeLevel(rgb[1]);
    const bi = nearestCubeLevel(rgb[2]);
    const cube_index: u8 = 16 + 36 * ri + 6 * gi + bi;
    const cube_rgb: Rgb = .{ cube_levels[ri], cube_levels[gi], cube_levels[bi] };

    const avg: u32 = (@as(u32, rgb[0]) + rgb[1] + rgb[2]) / 3;
    // Gray ramp: 232..255 are 8, 18, ..., 238
    const step: u32 = if (avg < 8) 0 else @min(23, (avg - 8 + 5) / 10);
    const gray: u8 = @intCast(8 + 10 * step);
    const gray_rgb: Rgb = .{ gray, gray, gray };

    return if (distanceSq(rgb, gray_rgb) < distanceSq(rgb, cube_rgb)) @intCast(232 + step) else cube_index;
}

/// Best of the terminal's 16 ANSI colors. Plain nearest-RGB would send every
/// mid or dark tone to black, so hue is matched first (against the palette
/// at full intensity) and intensity then picks the normal or bright variant.
/// Near-neutral colors walk the gray ladder black -> dark gray -> light gray -> white.
pub fn nearest16(colors: [16]Rgb, rgb: Rgb) u8 {
    const max: u32 = @max(rgb[0], @max(rgb[1], rgb[2]));
    const min: u32 = @min(rgb[0], @min(rgb[1], rgb[2]));

    if (max - min < 40) {
        // Neutral: 0 black, 8 dark gray, 7 light gray, 15 white
        return if (max < 32) 0 else if (max < 110) 8 else if (max < 200) 7 else 15;
    }
    if (max < 24) return 0;

    const target = normalizeHue(rgb, max);
    var best: u8 = 1;
    var best_d: u32 = std.math.maxInt(u32);
    for (1..7) |i| {
        const c = colors[i];
        const cm: u32 = @max(c[0], @max(c[1], c[2]));
        if (cm == 0) continue;
        const d = distanceSq(target, normalizeHue(c, cm));
        if (d < best_d) {
            best_d = d;
            best = @intCast(i);
        }
    }
    return if (max > 160) best + 8 else best;
}

inline fn normalizeHue(rgb: Rgb, max: u32) Rgb {
    return .{
        @intCast(@as(u32, rgb[0]) * 255 / max),
        @intCast(@as(u32, rgb[1]) * 255 / max),
        @intCast(@as(u32, rgb[2]) * 255 / max),
    };
}

fn encodeColor(shading: Shading, rgb: Rgb) Encoded {
    return switch (shading.palette) {
        .truecolor => .{ .rgb = .{ quantize(rgb[0]), quantize(rgb[1]), quantize(rgb[2]) } },
        .@"256" => .{ .index = nearest256(rgb) },
        .@"16" => .{ .index = nearest16(shading.theme.colors, rgb) },
    };
}

inline fn appendDecimal(out: *std.ArrayList(u8), v: u8) void {
    if (v >= 100) out.appendAssumeCapacity('0' + v / 100);
    if (v >= 10) out.appendAssumeCapacity('0' + (v / 10) % 10);
    out.appendAssumeCapacity('0' + v % 10);
}

const Layer = enum { fg, bg };

fn appendSgr(out: *std.ArrayList(u8), shading: Shading, layer: Layer, color: Encoded) void {
    switch (color) {
        .rgb => |rgb| {
            out.appendSliceAssumeCapacity(if (layer == .fg) "\x1b[38;2;" else "\x1b[48;2;");
            appendDecimal(out, rgb[0]);
            out.appendAssumeCapacity(';');
            appendDecimal(out, rgb[1]);
            out.appendAssumeCapacity(';');
            appendDecimal(out, rgb[2]);
            out.appendAssumeCapacity('m');
        },
        .index => |idx| switch (shading.palette) {
            .@"16" => {
                // 30-37 / 90-97 for fg, 40-47 / 100-107 for bg
                const base: u8 = if (idx < 8) (if (layer == .fg) 30 else 40) else (if (layer == .fg) 90 else 100);
                out.appendSliceAssumeCapacity("\x1b[");
                appendDecimal(out, base + (idx & 7));
                out.appendAssumeCapacity('m');
            },
            else => {
                out.appendSliceAssumeCapacity(if (layer == .fg) "\x1b[38;5;" else "\x1b[48;5;");
                appendDecimal(out, idx);
                out.appendAssumeCapacity('m');
            },
        },
    }
}

// ---- incremental re-dithering --------------------------------------------------

/// Pixels around a change that error diffusion must revisit
pub const redo_margin: u32 = 3;
/// A changed pixel needs this many changed neighbours (of 8) to count as
/// real motion rather than a noise outlier
pub const redo_support: u8 = 3;

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

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacityPrecise(allocator, target_rows * (target_cols * MAX_SHADED_CELL_BYTES + 1) + RESET_SGR.len);

    var prev_fg: ?Encoded = null;

    var row: u32 = 0;
    while (row < target_rows) : (row += 1) {
        var col: u32 = 0;
        while (col < target_cols) : (col += 1) {
            const pattern = ctx.pattern(col, row);

            // Blank cells show no ink and need no color
            if (pattern != 0) {
                const fg = encodeColor(shading, cellShade(image, col_spans[col], row_spans[row], invert, shading));
                if (prev_fg == null or !std.meta.eql(fg, prev_fg.?)) {
                    appendSgr(&out, shading, .fg, fg);
                    prev_fg = fg;
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

/// Subject mask gate for dots: present only when depth is on and the source
/// carries a mask
pub const MaskGate = struct {
    mask: types.Mask,
    cutoff: u8,

    /// The gate for this image under this shading, if any. Depth counts
    /// outward from the subject, so the confidence a dot needs is 255 - depth.
    pub fn from(image: Image, shading: Shading) ?MaskGate {
        const depth = shading.depth orelse return null;
        const mask = image.mask orelse return null;
        return .{ .mask = mask, .cutoff = 255 - depth };
    }

    pub inline fn allows(self: MaskGate, x: u32, y: u32, width: u32, height: u32) bool {
        return self.mask.at(x, y, width, height) >= self.cutoff;
    }
};

/// Samples a binary pixel buffer (stride == width) into Braille cells
const BinarySampler = struct {
    binary: []const u8,
    width: u32,
    height: u32,
    scale_x: f32,
    scale_y: f32,
    invert: bool,
    gate: ?MaskGate,

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
                if (is_set and self.gate != null) is_set = self.gate.?.allows(src_x, src_y, self.width, self.height);
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
        .gate = MaskGate.from(image, shading),
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

test "brightness shades between theme bg and fg, no background escape" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 128);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{255} ** 64;

    // Theme: dark blue background, warm foreground
    var theme = test_theme;
    theme.bg = .{ 0, 0, 40 };
    theme.fg = .{ 255, 200, 0 };
    const shading = Shading.init(.{ .gamma = 1.0, .palette = .truecolor, .theme = theme });
    const out = try binaryToBraille(&binary, image, 4, 2, false, shading, allocator);
    defer allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b[48;"));
    try std.testing.expect(std.mem.endsWith(u8, out, RESET_SGR));
    // gamma 1.0 at luma 128: t = 24 + 231 * 128/255 = 140
    // mix(bg, fg, 140): r = 255*140/255 = 140 -> 140, g = 200*140/255 = 109 -> 108, b = 40*115/255 = 18 -> 20
    // uniform image, so exactly one foreground escape for the whole frame
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "\x1b[38;2;"));
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;140;108;20m") != null);
}

test "shaded blank cells emit no color" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 128);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{0} ** 64;

    const out = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .gamma = 0.55, .color = true, .theme = test_theme }), allocator);
    defer allocator.free(out);

    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b[38;"));
}

test "color channel follows chroma" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 128);
    // Cb = 128 (neutral), Cr = 255 (strong red)
    var chroma_px: [4 * 4 * 2]u8 = undefined;
    for (0..16) |i| {
        chroma_px[i * 2] = 128;
        chroma_px[i * 2 + 1] = 255;
    }
    const image = Image{
        .data = &px.data,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
        .chroma = .{ .data = &chroma_px, .width = 4, .height = 4, .bytes_per_row = 8 },
    };
    const binary = [_]u8{255} ** 64;

    const out = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .color = true, .palette = .truecolor, .theme = test_theme }), allocator);
    defer allocator.free(out);

    // Y=128, Cr=+127 -> R clamps to 255, G = 128 - 90 = 38, B = 128; at full
    // intensity and quantized: (252, 36, 132)
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;252;36;132m") != null);
}

test "color without chroma falls back to theme fg" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 255);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{255} ** 64;

    const out = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .color = true, .palette = .truecolor, .theme = test_theme }), allocator);
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[38;2;252;252;252m") != null);
}

test "256 palette maps grays to the ramp and colors to the cube" {
    try std.testing.expectEqual(@as(u8, 16), nearest256(.{ 0, 0, 0 }));
    try std.testing.expectEqual(@as(u8, 231), nearest256(.{ 255, 255, 255 }));
    // Mid gray 128: ramp step 12 -> 128 exactly (index 244)
    try std.testing.expectEqual(@as(u8, 244), nearest256(.{ 128, 128, 128 }));
    // Pure red: cube (5,0,0) = 16 + 180 = 196
    try std.testing.expectEqual(@as(u8, 196), nearest256(.{ 255, 0, 0 }));
}

test "16 palette keeps hue at low intensity and grays on the ladder" {
    try std.testing.expectEqual(@as(u8, 9), nearest16(test_theme.colors, .{ 250, 10, 10 })); // bright red
    try std.testing.expectEqual(@as(u8, 1), nearest16(test_theme.colors, .{ 87, 12, 12 })); // dark red stays red
    try std.testing.expectEqual(@as(u8, 4), nearest16(test_theme.colors, .{ 10, 10, 120 })); // blue
    try std.testing.expectEqual(@as(u8, 11), nearest16(test_theme.colors, .{ 240, 230, 20 })); // bright yellow
    try std.testing.expectEqual(@as(u8, 0), nearest16(test_theme.colors, .{ 5, 5, 5 }));
    try std.testing.expectEqual(@as(u8, 8), nearest16(test_theme.colors, .{ 80, 80, 80 }));
    try std.testing.expectEqual(@as(u8, 7), nearest16(test_theme.colors, .{ 150, 150, 150 }));
    try std.testing.expectEqual(@as(u8, 15), nearest16(test_theme.colors, .{ 250, 250, 250 }));
}

test "palette modes emit 256 and 16 color escapes" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 255);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{255} ** 64;

    const out256 = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .gamma = 1.0, .palette = .@"256", .theme = test_theme }), allocator);
    defer allocator.free(out256);
    try std.testing.expect(std.mem.indexOf(u8, out256, "\x1b[38;5;231m") != null);

    const out16 = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .gamma = 1.0, .palette = .@"16", .theme = test_theme }), allocator);
    defer allocator.free(out16);
    // White -> bright white (index 15) -> SGR 97
    try std.testing.expect(std.mem.indexOf(u8, out16, "\x1b[97m") != null);
}

test "dilateChanged drops lone changes and grows real ones by the margin" {
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

    try std.testing.expectEqual(@as(u8, 0), out[3 * 32 + 3]);
    var count: usize = 0;
    for (out) |v| count += v;
    const side = 3 + redo_margin * 2;
    try std.testing.expectEqual(@as(usize, side * side), count);
    try std.testing.expectEqual(@as(u8, 1), out[(16 - redo_margin) * 32 + (16 - redo_margin)]);
    try std.testing.expectEqual(@as(u8, 0), out[(16 - redo_margin - 1) * 32 + 17]);
}

test "depth alone paints nothing: plain glyphs, no escapes" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 128);
    const image = Image{ .data = &px.data, .width = 8, .height = 8, .bytes_per_row = 8 };
    const binary = [_]u8{0} ** 64;

    const shading = Shading.init(.{ .depth = 128, .theme = test_theme });
    try std.testing.expect(!shading.enabled());
    const out = try binaryToBraille(&binary, image, 4, 2, false, shading, allocator);
    defer allocator.free(out);

    try std.testing.expectEqual(@as(usize, 26), out.len);
    try std.testing.expectEqual(@as(usize, 0), std.mem.count(u8, out, "\x1b["));
}

test "depth keeps dots only where the subject mask is confident" {
    const allocator = std.testing.allocator;
    const px = fullImage(8, 8, 128);
    // 2x2 mask: left half subject, right half background
    const mask_px = [_]u8{ 255, 0, 255, 0 };
    const image = Image{
        .data = &px.data,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
        .mask = .{ .data = &mask_px, .width = 2, .height = 2, .bytes_per_row = 2 },
    };
    const binary = [_]u8{255} ** 64;

    const out = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .depth = 100, .theme = test_theme }), allocator);
    defer allocator.free(out);

    const full = [_]u8{ 0xE2, 0xA3, 0xBF };
    const blank = [_]u8{ 0xE2, 0xA0, 0x80 };
    for (0..2) |row| {
        for (0..4) |col| {
            const offset = row * 13 + col * 3;
            const expected = if (col < 2) &full else &blank;
            try std.testing.expectEqualSlices(u8, expected, out[offset .. offset + 3]);
        }
    }

    // Without depth the mask is ignored
    const all = try binaryToBraille(&binary, image, 4, 2, false, .none, allocator);
    defer allocator.free(all);
    try std.testing.expectEqualSlices(u8, &full, all[9..12]);

    // Depth 255 reaches everything, depth 0 only where the mask is certain
    const everything = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .depth = 255, .theme = test_theme }), allocator);
    defer allocator.free(everything);
    try std.testing.expectEqualSlices(u8, &full, everything[9..12]);
    const nearest = try binaryToBraille(&binary, image, 4, 2, false, Shading.init(.{ .depth = 0, .theme = test_theme }), allocator);
    defer allocator.free(nearest);
    try std.testing.expectEqualSlices(u8, &full, nearest[0..3]);
    try std.testing.expectEqualSlices(u8, &blank, nearest[9..12]);
}
