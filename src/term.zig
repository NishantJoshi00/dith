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
