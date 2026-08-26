const std = @import("std");
const types = @import("types");
const Io = std.Io;

// =============================================================================
// Source configurations (tagged union)
// =============================================================================

pub const Strategy = enum { direct, pipelined };

pub const Source = union(enum) {
    cam: struct {
        warmup: u32 = 3,
        strategy: Strategy = .pipelined,
        /// Weight of the previous frame when blending, 0-1; steadies the dots
        /// against sensor noise. 0 = off.
        smooth: f32 = 0.7,
    },
    file: struct {
        path: []const u8 = "",
    },
};

// =============================================================================
// Mode configurations (tagged union)
// =============================================================================

pub const Mode = union(enum) {
    edge: struct {
        threshold: u8 = 2,
        invert: bool = false,
    },
    atkinson: struct {
        threshold: u8 = 128,
        invert: bool = false,
    },
    floyd_steinberg: struct {
        threshold: u8 = 128,
        invert: bool = false,
    },
    blue_noise: struct {
        threshold: u8 = 128,
        invert: bool = false,
    },
    bayer: struct {
        threshold: u8 = 128,
        invert: bool = false,
    },
};

// =============================================================================
// Shading options (apply to every mode)
// =============================================================================

pub const Shade = struct {
    /// Brightness channel exponent; present = channel on
    gamma: ?f32 = null,
    /// Color channel from the source's chroma
    color: bool = false,
    /// Depth: cell brightness follows nearness, far = background, near = foreground
    depth: bool = false,
    /// Depth model to use (.mlpackage or .mlmodelc); default downloads one
    model: ?[]const u8 = null,
    /// Override the terminal's reported foreground / background (RRGGBB)
    fg: ?types.Rgb = null,
    bg: ?types.Rgb = null,
};

// =============================================================================
// Args struct
// =============================================================================

pub const Args = struct {
    source: Source,
    mode: Mode,
    shade: Shade = .{},
};

// =============================================================================
// Errors
// =============================================================================

pub const ParseError = error{
    MissingSource,
    MissingMode,
    UnknownSource,
    UnknownMode,
    UnknownArgument,
    InvalidValue,
    MissingValue,
};

pub const ValidationError = error{
    FileNotFound,
    UnsupportedFormat,
    FileReadError,
    MissingFilePath,
};

pub const CliError = ParseError || ValidationError;

// =============================================================================
// Comptime parsing helpers
// =============================================================================

fn parseValue(comptime T: type, value: []const u8) ?T {
    if (T == []const u8) {
        return value;
    } else if (T == bool) {
        // Bools are flags, shouldn't have values passed here
        return null;
    } else if (T == u8 or T == u32) {
        return std.fmt.parseInt(T, value, 10) catch null;
    } else if (T == f32) {
        return std.fmt.parseFloat(T, value) catch null;
    } else if (T == types.Rgb) {
        return parseHexColor(value);
    } else if (@typeInfo(T) == .optional) {
        // Unwrap so a failed parse stays a failure instead of a present-but-null value
        const inner = parseValue(@typeInfo(T).optional.child, value) orelse return null;
        return inner;
    } else if (@typeInfo(T) == .@"enum") {
        inline for (@typeInfo(T).@"enum".fields) |field| {
            if (std.mem.eql(u8, value, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
    return null;
}

/// "RRGGBB" or "#RRGGBB"
fn parseHexColor(value: []const u8) ?types.Rgb {
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (hex.len != 6) return null;
    var rgb: types.Rgb = undefined;
    for (0..3) |i| {
        rgb[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return null;
    }
    return rgb;
}

fn setField(comptime T: type, ptr: *T, field_name: []const u8, value: ?[]const u8) ParseError!bool {
    const info = @typeInfo(T).@"struct";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, field_name, field.name)) {
            if (field.type == bool) {
                // Bool is a flag - just set to true
                @field(ptr, field.name) = true;
                return true;
            } else if (value) |v| {
                if (parseValue(field.type, v)) |parsed| {
                    @field(ptr, field.name) = parsed;
                    return true;
                } else {
                    return ParseError.InvalidValue;
                }
            } else {
                return ParseError.MissingValue;
            }
        }
    }
    return false; // Field not found
}

fn getActivePayload(comptime U: type, u: *U) ?struct { name: []const u8, ptr: *anyopaque } {
    const info = @typeInfo(U).@"union";
    inline for (info.fields) |field| {
        if (u.* == @field(std.meta.Tag(U), field.name)) {
            return .{
                .name = field.name,
                .ptr = &@field(u, field.name),
            };
        }
    }
    return null;
}

// =============================================================================
// Main parsing
// =============================================================================

/// Parse process arguments. Returns null when help was requested; the caller
/// is responsible for printing it (see `printHelp`).
pub fn parse(io: Io, process_args: std.process.Args) CliError!?Args {
    var iter = process_args.iterate();
    const args = try parseFromIter(&iter);

    if (args) |a| {
        // Validate file source has path
        switch (a.source) {
            .file => |f| {
                if (f.path.len == 0) {
                    return ValidationError.MissingFilePath;
                }
                try validateFile(io, f.path);
            },
            else => {},
        }
    }

    return args;
}

/// Parse from any iterator whose `next()` yields `?[]const u8`-compatible
/// slices. Returns null when `+help` is encountered.
pub fn parseFromIter(iter: anytype) ParseError!?Args {
    // Skip program name
    _ = iter.next();

    // First arg: must be +source=X or +help
    const first = iter.next() orelse return ParseError.MissingSource;
    if (std.mem.eql(u8, first, "+help")) {
        return null;
    }
    if (!std.mem.startsWith(u8, first, "+source=")) {
        return ParseError.MissingSource;
    }
    var source = initVariant(Source, first["+source=".len..]) orelse return ParseError.UnknownSource;

    // Second arg: must be +mode=Y
    const second = iter.next() orelse return ParseError.MissingMode;
    if (!std.mem.startsWith(u8, second, "+mode=")) {
        return ParseError.MissingMode;
    }
    var mode = initVariant(Mode, second["+mode=".len..]) orelse return ParseError.UnknownMode;
    var shade: Shade = .{};

    // Remaining args: distribute to source, mode, or shading based on field name
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "+help")) {
            return null;
        }

        if (!std.mem.startsWith(u8, arg, "+")) {
            return ParseError.UnknownArgument;
        }

        const rest = arg[1..];
        var field_name: []const u8 = rest;
        var value: ?[]const u8 = null;

        if (std.mem.indexOf(u8, rest, "=")) |eq_pos| {
            field_name = rest[0..eq_pos];
            value = rest[eq_pos + 1 ..];
        }

        // Try source first, then mode, then shading
        const found_in_source = try setFieldOnUnion(Source, &source, field_name, value);
        if (!found_in_source) {
            const found_in_mode = try setFieldOnUnion(Mode, &mode, field_name, value);
            if (!found_in_mode) {
                const found_in_shade = try setField(Shade, &shade, field_name, value);
                if (!found_in_shade) {
                    return ParseError.UnknownArgument;
                }
            }
        }
    }

    if (shade.gamma) |g| {
        if (!(g > 0) or !std.math.isFinite(g)) return ParseError.InvalidValue;
    }
    switch (source) {
        .cam => |c| if (!(c.smooth >= 0 and c.smooth <= 1)) return ParseError.InvalidValue,
        else => {},
    }

    return Args{
        .source = source,
        .mode = mode,
        .shade = shade,
    };
}

fn initVariant(comptime U: type, variant_name: []const u8) ?U {
    const info = @typeInfo(U).@"union";
    inline for (info.fields) |field| {
        if (std.mem.eql(u8, variant_name, field.name)) {
            // Initialize with defaults
            if (@typeInfo(field.type) == .@"struct") {
                return @unionInit(U, field.name, .{});
            }
        }
    }
    return null;
}

fn setFieldOnUnion(comptime U: type, u: *U, field_name: []const u8, value: ?[]const u8) ParseError!bool {
    const info = @typeInfo(U).@"union";
    inline for (info.fields) |ufield| {
        if (u.* == @field(std.meta.Tag(U), ufield.name)) {
            const PayloadType = ufield.type;
            if (@typeInfo(PayloadType) == .@"struct") {
                return setField(PayloadType, &@field(u, ufield.name), field_name, value);
            }
        }
    }
    return false;
}

// =============================================================================
// File validation
// =============================================================================

const ImageFormat = types.ImageFormat;

const supported_formats = .{
    .{ ImageFormat.png, "\x89PNG\x0D\x0A\x1A\x0A" },
    .{ ImageFormat.jpeg, "\xFF\xD8\xFF" },
    .{ ImageFormat.bmp, "BM" },
};

fn detectFormat(header: []const u8) ImageFormat {
    inline for (supported_formats) |fmt| {
        const magic = fmt[1];
        if (header.len >= magic.len and std.mem.eql(u8, header[0..magic.len], magic)) {
            return fmt[0];
        }
    }
    return .unknown;
}

fn validateFile(io: Io, path: []const u8) ValidationError!void {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch {
        return ValidationError.FileNotFound;
    };
    defer file.close(io);

    var header: [8]u8 = undefined;
    const bytes_read = file.readStreaming(io, &.{&header}) catch {
        return ValidationError.FileReadError;
    };

    if (detectFormat(header[0..bytes_read]) == .unknown) {
        return ValidationError.UnsupportedFormat;
    }
}

// =============================================================================
// Help
// =============================================================================

pub fn printHelp(io: Io) void {
    const help_text =
        \\dith - Terminal dithering tool
        \\
        \\USAGE:
        \\    dith +source=<SOURCE> +mode=<MODE> [options...]
        \\
        \\SOURCES:
        \\    cam                Live camera feed
        \\      +warmup=<N>        Warmup frames (default: 3)
        \\      +strategy=<S>      direct | pipelined (default: pipelined)
        \\      +smooth=<S>        Steadiness, 0-1: holds the dots against noise and small
        \\                         motion (default: 0.7, 0 = off)
        \\
        \\    file               Image file
        \\      +path=<PATH>       Path to image file (required)
        \\
        \\MODES:
        \\    edge               Edge detection (Braille output)
        \\      +threshold=<N>     Sensitivity 0-255 (default: 2)
        \\      +invert            Invert output
        \\
        \\    atkinson           Atkinson dithering (high contrast, 75% error diffusion)
        \\      +threshold=<N>     Binarization threshold 0-255 (default: 128)
        \\      +invert            Invert output
        \\
        \\    floyd_steinberg    Floyd-Steinberg dithering (smooth gradients)
        \\      +threshold=<N>     Binarization threshold 0-255 (default: 128)
        \\      +invert            Invert output
        \\
        \\    blue_noise         Blue noise dithering (organic, pattern-free)
        \\      +threshold=<N>     Threshold adjustment 0-255 (default: 128)
        \\      +invert            Invert output
        \\
        \\    bayer              Bayer ordered dithering (fast, retro crosshatch)
        \\      +threshold=<N>     Threshold adjustment 0-255 (default: 128)
        \\      +invert            Invert output
        \\
        \\SHADING (any mode, off by default; only your terminal's own
        \\colors are used, mixed across cells):
        \\    +gamma=<G>         Shade dots by brightness, curve exponent G
        \\                       (0.55 compensates the dither's washed-out midtones;
        \\                        lower = brighter shadows, higher = deeper contrast)
        \\    +color             Color dots from the camera or image
        \\    +depth             Brightness follows distance: near things in the
        \\                       foreground color, far things fade to the background.
        \\                       Uses an on-device depth model (downloaded to ~/.cache/dith)
        \\    +model=<PATH>      Depth model to use instead (.mlpackage or .mlmodelc)
        \\    +fg=RRGGBB         Override the terminal's foreground color
        \\    +bg=RRGGBB         Override the terminal's background color
        \\
        \\    dith +theme        Show the colors your terminal reports
        \\
        \\EXAMPLES:
        \\    dith +source=cam +mode=edge
        \\    dith +source=cam +mode=blue_noise
        \\    dith +source=file +mode=atkinson +path=photo.png +invert
        \\    dith +source=cam +mode=floyd_steinberg +gamma=0.55 +color
        \\    dith +source=cam +mode=atkinson +color +depth
        \\
    ;
    var buffer: [4096]u8 = undefined;
    var writer = Io.File.stderr().writerStreaming(io, &buffer);
    const stderr = &writer.interface;
    stderr.writeAll(help_text) catch {};
    stderr.flush() catch {};
}

pub fn printErrorAndHelp(io: Io, err: CliError) void {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writerStreaming(io, &buffer);
    const stderr = &writer.interface;
    const msg: []const u8 = switch (err) {
        ParseError.MissingSource => "error: +source is required\n\n",
        ParseError.MissingMode => "error: +mode is required\n\n",
        ParseError.UnknownSource => "error: unknown source\n\n",
        ParseError.UnknownMode => "error: unknown mode\n\n",
        ParseError.UnknownArgument => "error: unknown argument\n\n",
        ParseError.InvalidValue => "error: invalid value\n\n",
        ParseError.MissingValue => "error: missing value for argument\n\n",
        ValidationError.FileNotFound => "error: file not found\n\n",
        ValidationError.UnsupportedFormat => "error: unsupported image format (use png, jpg, or bmp)\n\n",
        ValidationError.FileReadError => "error: could not read file\n\n",
        ValidationError.MissingFilePath => "error: +source=file requires a file path\n\n",
    };
    stderr.writeAll(msg) catch {};
    stderr.flush() catch {};
    printHelp(io);
}

// =============================================================================
// Tests
// =============================================================================

const SliceIter = struct {
    slice: []const []const u8,
    index: usize = 0,

    pub fn next(self: *SliceIter) ?[]const u8 {
        if (self.index >= self.slice.len) return null;
        defer self.index += 1;
        return self.slice[self.index];
    }
};

test "parse requires source and mode" {
    var iter = SliceIter{ .slice = &.{"dith"} };
    const result = parseFromIter(&iter);
    try std.testing.expectError(ParseError.MissingSource, result);
}

test "parse requires mode" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam" } };
    const result = parseFromIter(&iter);
    try std.testing.expectError(ParseError.MissingMode, result);
}

test "parse basic cam + edge" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=edge" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    try std.testing.expectEqual(Source.cam, std.meta.activeTag(args.?.source));
    try std.testing.expectEqual(Mode.edge, std.meta.activeTag(args.?.mode));
}

test "parse cam with options" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=edge", "+warmup=10", "+strategy=direct" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    switch (args.?.source) {
        .cam => |c| {
            try std.testing.expectEqual(@as(u32, 10), c.warmup);
            try std.testing.expectEqual(Strategy.direct, c.strategy);
        },
        else => unreachable,
    }
}

test "parse edge with options" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=edge", "+threshold=50", "+invert" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    switch (args.?.mode) {
        .edge => |e| {
            try std.testing.expectEqual(@as(u8, 50), e.threshold);
            try std.testing.expectEqual(true, e.invert);
        },
        else => unreachable,
    }
}

test "parse atkinson mode" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=atkinson", "+threshold=100" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    switch (args.?.mode) {
        .atkinson => |a| {
            try std.testing.expectEqual(@as(u8, 100), a.threshold);
            try std.testing.expectEqual(false, a.invert);
        },
        else => unreachable,
    }
}

test "parse floyd_steinberg mode" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=floyd_steinberg", "+invert" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    switch (args.?.mode) {
        .floyd_steinberg => |fs| {
            try std.testing.expectEqual(@as(u8, 128), fs.threshold); // default
            try std.testing.expectEqual(true, fs.invert);
        },
        else => unreachable,
    }
}

test "parse blue_noise mode" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=blue_noise", "+threshold=64" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    switch (args.?.mode) {
        .blue_noise => |bn| {
            try std.testing.expectEqual(@as(u8, 64), bn.threshold);
            try std.testing.expectEqual(false, bn.invert);
        },
        else => unreachable,
    }
}

test "parse bayer mode" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+invert" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    switch (args.?.mode) {
        .bayer => |b| {
            try std.testing.expectEqual(@as(u8, 128), b.threshold); // default
            try std.testing.expectEqual(true, b.invert);
        },
        else => unreachable,
    }
}

test "parse file source with path" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=file", "+mode=edge", "+path=image.png" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    switch (args.?.source) {
        .file => |f| {
            try std.testing.expectEqualStrings("image.png", f.path);
        },
        else => unreachable,
    }
}

test "parse shading options" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+gamma=0.8", "+color" } };
    const args = try parseFromIter(&iter);
    try std.testing.expect(args != null);
    try std.testing.expectEqual(@as(f32, 0.8), args.?.shade.gamma.?);
    try std.testing.expectEqual(true, args.?.shade.color);
}

test "parse shading defaults to off" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer" } };
    const args = try parseFromIter(&iter);
    try std.testing.expectEqual(@as(?f32, null), args.?.shade.gamma);
    try std.testing.expectEqual(false, args.?.shade.color);
    try std.testing.expectEqual(false, args.?.shade.depth);
    try std.testing.expectEqual(@as(?types.Rgb, null), args.?.shade.fg);
}

test "parse smooth" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+smooth=0" } };
    const args = try parseFromIter(&iter);
    try std.testing.expectEqual(@as(f32, 0), args.?.source.cam.smooth);
    var bad = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+smooth=1.5" } };
    try std.testing.expectError(ParseError.InvalidValue, parseFromIter(&bad));
}

test "parse depth and theme overrides" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+depth", "+fg=#ffcc00", "+bg=101010" } };
    const args = try parseFromIter(&iter);
    try std.testing.expectEqual(true, args.?.shade.depth);
    try std.testing.expectEqual(types.Rgb{ 0xff, 0xcc, 0x00 }, args.?.shade.fg.?);
    try std.testing.expectEqual(types.Rgb{ 0x10, 0x10, 0x10 }, args.?.shade.bg.?);
}

test "parse rejects bad colors" {
    var iter1 = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+fg=zzz" } };
    try std.testing.expectError(ParseError.InvalidValue, parseFromIter(&iter1));
}

test "parse rejects bad gamma" {
    var iter1 = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+gamma=0" } };
    try std.testing.expectError(ParseError.InvalidValue, parseFromIter(&iter1));
    var iter2 = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+gamma=abc" } };
    try std.testing.expectError(ParseError.InvalidValue, parseFromIter(&iter2));
    var iter3 = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=bayer", "+gamma" } };
    try std.testing.expectError(ParseError.MissingValue, parseFromIter(&iter3));
}

test "parse unknown source" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=video", "+mode=edge" } };
    const result = parseFromIter(&iter);
    try std.testing.expectError(ParseError.UnknownSource, result);
}

test "parse unknown mode" {
    var iter = SliceIter{ .slice = &.{ "dith", "+source=cam", "+mode=ascii" } };
    const result = parseFromIter(&iter);
    try std.testing.expectError(ParseError.UnknownMode, result);
}
