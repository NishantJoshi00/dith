const std = @import("std");
const types = @import("types");
const Image = types.Image;

/// Terminal dimensions
pub const TermSize = struct {
    cols: u32,
    rows: u32,
};

/// Get current terminal size
pub fn getTermSize() !TermSize {
    // Use TIOCGWINSZ ioctl to get terminal size on Unix systems
    var winsize: std.posix.winsize = undefined;
    const request: c_int = @intCast(std.c.T.IOCGWINSZ);
    const result = std.c.ioctl(std.posix.STDOUT_FILENO, request, &winsize);

    if (result == -1) {
        return error.TermSizeUnavailable;
    }

    return TermSize{
        .cols = winsize.col,
        .rows = winsize.row,
    };
}

/// Output dimensions for Braille rendering
pub const BrailleDimensions = struct {
    cols: u32,
    rows: u32,
};

/// Calculate optimal Braille dimensions to fit image within terminal bounds
/// while maintaining 1:1 pixel aspect ratio. Scales based on whichever dimension
/// (width or height) is the limiting factor.
pub fn calculateBrailleDimensions(image: Image, term_size: TermSize) BrailleDimensions {
    // Each Braille char = 2 pixels wide, 4 pixels tall
    const pixels_per_braille_width = 2;
    const pixels_per_braille_height = 4;

    // Calculate scale factor needed to fit width
    const scale_for_width = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(term_size.cols * pixels_per_braille_width));

    // Calculate scale factor needed to fit height
    const scale_for_height = @as(f32, @floatFromInt(image.height)) / @as(f32, @floatFromInt(term_size.rows * pixels_per_braille_height));

    // Use the larger scale (which produces smaller output) to ensure we fit both dimensions
    const scale = @max(scale_for_width, scale_for_height);

    // Apply scale to both dimensions
    const output_pixel_width = @as(f32, @floatFromInt(image.width)) / scale;
    const output_pixel_height = @as(f32, @floatFromInt(image.height)) / scale;

    // Convert to Braille dimensions
    var output_cols = @as(u32, @intFromFloat(output_pixel_width)) / pixels_per_braille_width;
    var output_rows = @as(u32, @intFromFloat(output_pixel_height)) / pixels_per_braille_height;

    // Ensure at least 1x1
    if (output_cols == 0) output_cols = 1;
    if (output_rows == 0) output_rows = 1;

    return .{
        .cols = output_cols,
        .rows = output_rows,
    };
}

// =============================================================================
// Theme colors (OSC 10 / 11 / 4)
// =============================================================================

pub const Rgb = types.Rgb;
pub const Theme = types.Theme;

/// xterm's stock colors: what shading assumes when the terminal does not answer
pub const default_theme: Theme = .{
    .fg = .{ 255, 255, 255 },
    .bg = .{ 0, 0, 0 },
    .colors = .{
        .{ 0, 0, 0 },       .{ 205, 0, 0 },   .{ 0, 205, 0 },   .{ 205, 205, 0 },
        .{ 0, 0, 238 },     .{ 205, 0, 205 }, .{ 0, 205, 205 }, .{ 229, 229, 229 },
        .{ 127, 127, 127 }, .{ 255, 0, 0 },   .{ 0, 255, 0 },   .{ 255, 255, 0 },
        .{ 92, 92, 255 },   .{ 255, 0, 255 }, .{ 0, 255, 255 }, .{ 255, 255, 255 },
    },
};

const theme_query = blk: {
    var q: []const u8 = "\x1b]10;?\x1b\\\x1b]11;?\x1b\\";
    for (0..16) |i| q = q ++ std.fmt.comptimePrint("\x1b]4;{d};?\x1b\\", .{i});
    break :blk q;
};
const theme_reply_count = 18;

/// Ask the terminal for its foreground, background and 16-color palette.
/// Best effort: anything the terminal does not answer within `timeout_ms`
/// keeps the default. Costs one round-trip, so only call it when needed.
pub fn queryTheme(timeout_ms: i32) Theme {
    var theme = default_theme;
    const in_fd = std.posix.STDIN_FILENO;
    const out_fd = std.posix.STDOUT_FILENO;
    if (std.c.isatty(in_fd) == 0 or std.c.isatty(out_fd) == 0) return theme;

    // Raw-ish input: replies must not wait for a newline or echo on screen
    var original: std.c.termios = undefined;
    if (std.c.tcgetattr(in_fd, &original) != 0) return theme;
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    if (std.c.tcsetattr(in_fd, .NOW, &raw) != 0) return theme;
    defer _ = std.c.tcsetattr(in_fd, .NOW, &original);

    var written: usize = 0;
    while (written < theme_query.len) {
        const n = std.c.write(out_fd, theme_query[written..].ptr, theme_query.len - written);
        if (n <= 0) return theme;
        written += @intCast(n);
    }

    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    var wait_ms = timeout_ms;
    while (len < buf.len) {
        var fds = [_]std.c.pollfd{.{ .fd = in_fd, .events = std.c.POLL.IN, .revents = 0 }};
        if (std.c.poll(&fds, 1, wait_ms) <= 0) break;
        const n = std.c.read(in_fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
        if (parseThemeReplies(buf[0..len], &theme) >= theme_reply_count) break;
        // Replies arrive as one burst; once the first is in, wait only briefly for the rest
        wait_ms = 30;
    }
    return theme;
}

/// Parse OSC color replies ("ESC ] 10 ; rgb:RRRR/GGGG/BBBB ST") into `theme`.
/// Returns how many complete replies were recognized.
pub fn parseThemeReplies(data: []const u8, theme: *Theme) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, data, i, "\x1b]")) |start| {
        var pos = start + 2;
        const code = parseDecimal(data, &pos) orelse {
            i = start + 2;
            continue;
        };
        var index: ?usize = null;
        if (code == 4) {
            if (pos >= data.len or data[pos] != ';') {
                i = start + 2;
                continue;
            }
            pos += 1;
            index = parseDecimal(data, &pos);
        }
        if (pos >= data.len or data[pos] != ';') {
            i = start + 2;
            continue;
        }
        pos += 1;
        const rgb = parseXColor(data, &pos) orelse {
            i = start + 2;
            continue;
        };
        // Terminator: BEL or ESC \
        if (pos < data.len and data[pos] == 0x07) {
            pos += 1;
        } else if (pos + 1 < data.len and data[pos] == 0x1b and data[pos + 1] == '\\') {
            pos += 2;
        } else {
            // Incomplete reply; the rest may still be in flight
            break;
        }

        switch (code) {
            10 => theme.fg = rgb,
            11 => theme.bg = rgb,
            4 => if (index) |idx| {
                if (idx < 16) theme.colors[idx] = rgb;
            },
            else => {},
        }
        count += 1;
        i = pos;
    }
    return count;
}

fn parseDecimal(data: []const u8, pos: *usize) ?usize {
    var value: usize = 0;
    var digits: usize = 0;
    while (pos.* < data.len and std.ascii.isDigit(data[pos.*])) : (pos.* += 1) {
        value = value * 10 + (data[pos.*] - '0');
        digits += 1;
    }
    return if (digits == 0) null else value;
}

/// "rgb:RR/GG/BB" with 1-4 hex digits per channel, scaled to 8 bits
fn parseXColor(data: []const u8, pos: *usize) ?Rgb {
    if (!std.mem.startsWith(u8, data[pos.*..], "rgb:")) return null;
    pos.* += 4;
    var rgb: Rgb = undefined;
    for (0..3) |ch| {
        if (ch > 0) {
            if (pos.* >= data.len or data[pos.*] != '/') return null;
            pos.* += 1;
        }
        var value: u32 = 0;
        var digits: u32 = 0;
        while (pos.* < data.len and digits < 4 and std.ascii.isHex(data[pos.*])) : (pos.* += 1) {
            const digit: u32 = std.fmt.charToDigit(data[pos.*], 16) catch unreachable;
            value = value * 16 + digit;
            digits += 1;
        }
        if (digits == 0) return null;
        const max: u32 = (@as(u32, 1) << @intCast(4 * digits)) - 1;
        rgb[ch] = @intCast(value * 255 / max);
    }
    return rgb;
}

/// Clear the terminal screen
/// Accepts any writer type (typically a buffered stdout writer)
pub fn clearScreen(stdout: anytype) !void {
    // ANSI escape code to clear screen and move cursor to home
    try stdout.writeAll("\x1B[2J\x1B[H");
}

/// Move cursor to top-left
/// Accepts any writer type (typically a buffered stdout writer)
pub fn moveCursorHome(stdout: anytype) !void {
    try stdout.writeAll("\x1B[H");
}

/// Synchronized output (DEC 2026): terminals that support it hold the screen
/// until the frame is complete, so redraws never show half-drawn or blank
/// states. Others ignore it.
pub fn beginFrame(stdout: anytype) !void {
    try stdout.writeAll("\x1B[?2026h");
}

pub fn endFrame(stdout: anytype) !void {
    try stdout.writeAll("\x1B[?2026l");
}

/// Erase from the cursor to the end of the line
pub fn clearToLineEnd(stdout: anytype) !void {
    try stdout.writeAll("\x1B[K");
}

/// Write multi-line text with each line placed at an explicit row (1-based),
/// instead of relying on newlines. A newline on the terminal's last row would
/// scroll the whole screen, which shows as a one-line jitter every frame.
pub fn writeLinesInPlace(stdout: anytype, text: []const u8, first_row: u32) !void {
    var row = first_row;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 and lines.peek() == null) break; // trailing newline
        try stdout.print("\x1B[{d};1H", .{row});
        try stdout.writeAll(line);
        row += 1;
    }
}

test "terminal size" {
    // Skip test if not running in a real terminal
    const size = getTermSize() catch |err| {
        if (err == error.TermSizeUnavailable) return error.SkipZigTest;
        return err;
    };
    try std.testing.expect(size.cols > 0);
    try std.testing.expect(size.rows > 0);
}

test "calculate Braille dimensions - width limited" {
    // Wide terminal, narrow image - width should be the limiting factor
    const test_image = Image{
        .data = &[_]u8{0} ** 100,
        .width = 800,
        .height = 600,
        .bytes_per_row = 800,
    };

    const term_size = TermSize{ .cols = 80, .rows = 100 }; // 160 pixels wide, 400 pixels tall
    const dims = calculateBrailleDimensions(test_image, term_size);

    // Scale for width: 800 / 160 = 5
    // Scale for height: 600 / 400 = 1.5
    // Use larger scale (5), so width is limiting
    // Output: 800/5 = 160px wide = 80 cols, 600/5 = 120px tall = 30 rows
    try std.testing.expectEqual(@as(u32, 80), dims.cols);
    try std.testing.expectEqual(@as(u32, 30), dims.rows);
}

test "calculate Braille dimensions - height limited" {
    // Narrow terminal, tall image - height should be the limiting factor
    const tall_image = Image{
        .data = &[_]u8{0} ** 100,
        .width = 800,
        .height = 1600,
        .bytes_per_row = 800,
    };

    const term_size = TermSize{ .cols = 100, .rows = 30 }; // 200 pixels wide, 120 pixels tall
    const dims = calculateBrailleDimensions(tall_image, term_size);

    // Scale for width: 800 / 200 = 4
    // Scale for height: 1600 / 120 = 13.33...
    // Use larger scale (13.33), so height is limiting
    // Output: 800/13.33 = 60px wide = 30 cols, 1600/13.33 = 120px tall = 30 rows
    try std.testing.expectEqual(@as(u32, 30), dims.cols);
    try std.testing.expectEqual(@as(u32, 30), dims.rows);
}

test "calculate Braille dimensions - maintains aspect ratio" {
    // Square image 400x400 in square-ish terminal
    const square_image = Image{
        .data = &[_]u8{0} ** 100,
        .width = 400,
        .height = 400,
        .bytes_per_row = 400,
    };

    const term_size = TermSize{ .cols = 40, .rows = 20 }; // 80 pixels wide, 80 pixels tall
    const dims = calculateBrailleDimensions(square_image, term_size);

    // Scale for width: 400 / 80 = 5
    // Scale for height: 400 / 80 = 5
    // Both equal, so use 5
    // Output: 400/5 = 80px = 40 cols, 400/5 = 80px = 20 rows
    try std.testing.expectEqual(@as(u32, 40), dims.cols);
    try std.testing.expectEqual(@as(u32, 20), dims.rows);
}

test "calculate Braille dimensions - wide image in wide terminal" {
    // Wide image 1600x800 (2:1 aspect ratio) in wide terminal
    const wide_image = Image{
        .data = &[_]u8{0} ** 100,
        .width = 1600,
        .height = 800,
        .bytes_per_row = 1600,
    };

    const term_size = TermSize{ .cols = 80, .rows = 40 }; // 160 pixels wide, 160 pixels tall
    const dims = calculateBrailleDimensions(wide_image, term_size);

    // Scale for width: 1600 / 160 = 10
    // Scale for height: 800 / 160 = 5
    // Use larger scale (10), width is limiting
    // Output: 1600/10 = 160px = 80 cols, 800/10 = 80px = 20 rows
    try std.testing.expectEqual(@as(u32, 80), dims.cols);
    try std.testing.expectEqual(@as(u32, 20), dims.rows);
}

test "calculate Braille dimensions - minimum output" {
    // Very small image
    const tiny_image = Image{
        .data = &[_]u8{0} ** 100,
        .width = 10,
        .height = 5,
        .bytes_per_row = 10,
    };

    const term_size = TermSize{ .cols = 100, .rows = 50 };
    const dims = calculateBrailleDimensions(tiny_image, term_size);

    // Should always return at least 1x1
    try std.testing.expect(dims.cols >= 1);
    try std.testing.expect(dims.rows >= 1);
}

test "calculate Braille dimensions - 1080p in common terminal" {
    // Test with 1080p (1920x1080) in 160x45 terminal
    const hd_image = Image{
        .data = &[_]u8{0} ** 100,
        .width = 1920,
        .height = 1080,
        .bytes_per_row = 1920,
    };

    const term_size = TermSize{ .cols = 160, .rows = 45 }; // 320 pixels wide, 180 pixels tall
    const dims = calculateBrailleDimensions(hd_image, term_size);

    // Scale for width: 1920 / 320 = 6
    // Scale for height: 1080 / 180 = 6
    // Both equal at 6
    // Output: 1920/6 = 320px = 160 cols, 1080/6 = 180px = 45 rows
    try std.testing.expectEqual(@as(u32, 160), dims.cols);
    try std.testing.expectEqual(@as(u32, 45), dims.rows);
}

test "parseThemeReplies reads fg, bg and palette entries" {
    var theme = default_theme;
    const replies = "\x1b]10;rgb:ffff/e5e5/0000\x1b\\" ++ "\x1b]11;rgb:1a/1b/1c\x07" ++ "\x1b]4;1;rgb:c/0/0\x1b\\";
    try std.testing.expectEqual(@as(usize, 3), parseThemeReplies(replies, &theme));
    try std.testing.expectEqual(Rgb{ 255, 229, 0 }, theme.fg);
    try std.testing.expectEqual(Rgb{ 0x1a, 0x1b, 0x1c }, theme.bg);
    try std.testing.expectEqual(Rgb{ 204, 0, 0 }, theme.colors[1]);
    // Untouched entries keep defaults
    try std.testing.expectEqual(default_theme.colors[2], theme.colors[2]);
}

test "parseThemeReplies ignores partial and unrelated input" {
    var theme = default_theme;
    try std.testing.expectEqual(@as(usize, 0), parseThemeReplies("\x1b]10;rgb:ffff/ffff", &theme));
    try std.testing.expectEqual(@as(usize, 0), parseThemeReplies("hello\x1b[31m", &theme));
    try std.testing.expectEqual(default_theme.fg, theme.fg);
}

test "writeLinesInPlace positions each row and never emits a newline" {
    var buffer: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try writeLinesInPlace(&w, "ab\ncd\n", 1);
    try std.testing.expectEqualStrings("\x1B[1;1Hab\x1B[2;1Hcd", w.buffered());
}
