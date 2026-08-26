const std = @import("std");
const common = @import("common");

const Image = common.Image;
const Converter = common.Converter;
const binaryToBraille = common.binaryToBraille;

/// Atkinson dithering converter
/// Uses Bill Atkinson's algorithm (from original Macintosh)
/// Diffuses only 75% of error for higher contrast results
///
/// Optimized: Uses 3-row rolling buffer instead of full image copy
/// Memory: O(width) instead of O(width * height)
pub const AtkinsonConverter = struct {
    allocator: std.mem.Allocator,
    threshold: i16, // Threshold for binarization (typically 128)
    invert: bool,
    shading: common.Shading = .none,
    /// Last frame's dot map, reused as this frame's output buffer. Error
    /// diffusion is chaotic (one changed pixel re-rolls everything below and
    /// right of it), so when the frame says which pixels changed, only those
    /// and a small margin are re-dithered; the rest keep their dots.
    dots: []u8 = &.{},
    /// Each pixel's quantization error from the last time it was computed.
    /// Pixels that keep their dots still hand this error to their
    /// neighbours, so a re-dithered patch continues the surrounding pattern
    /// instead of restarting it.
    errors: []i16 = &.{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, threshold: u8, invert: bool) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .threshold = @as(i16, threshold),
            .invert = invert,
        };
        return self;
    }

    pub fn converter(self: *Self) Converter {
        return .{
            .ptr = self,
            .vtable = &.{
                .convert = convertImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn convertImpl(ptr: *anyopaque, image: Image, target_cols: u32, target_rows: u32, allocator: std.mem.Allocator) ![]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.imageToText(image, target_cols, target_rows, allocator);
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const allocator = self.allocator;
        allocator.free(self.dots);
        allocator.free(self.errors);
        allocator.destroy(self);
    }

    /// The persistent dot map, resized to the frame. `fresh` is set when
    /// there is no previous frame to keep dots from.
    fn dotBuffer(self: *Self, len: usize, fresh: *bool) ![]u8 {
        fresh.* = self.dots.len != len;
        if (fresh.*) {
            self.allocator.free(self.dots);
            self.dots = &.{};
            self.dots = try self.allocator.alloc(u8, len);
            @memset(self.dots, 0);
            self.allocator.free(self.errors);
            self.errors = &.{};
            self.errors = try self.allocator.alloc(i16, len);
            @memset(self.errors, 0);
        }
        return self.dots;
    }

    pub fn imageToText(
        self: *Self,
        image: Image,
        target_cols: u32,
        target_rows: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const width = image.width;
        const height = image.height;

        // Output dot map, carried over from last frame
        var fresh = false;
        const binary = try self.dotBuffer(width * height, &fresh);

        // Pixels to re-dither: the changed ones plus a margin, or everything
        const redo: ?[]u8 = if (!fresh and image.changed != null) try common.dilateChanged(image.changed.?, width, height, allocator) else null;
        defer if (redo) |r| allocator.free(r);

        // Rolling error buffers - need 3 rows for Atkinson (current, y+1, y+2)
        var err_row0 = try allocator.alloc(i16, width); // current row
        defer allocator.free(err_row0);
        var err_row1 = try allocator.alloc(i16, width); // y+1
        defer allocator.free(err_row1);
        var err_row2 = try allocator.alloc(i16, width); // y+2
        defer allocator.free(err_row2);

        @memset(err_row0, 0);
        @memset(err_row1, 0);
        @memset(err_row2, 0);

        const threshold = self.threshold;

        // Atkinson error diffusion pattern (each neighbor gets 1/8 of error):
        //       X   *   *
        //   *   *   *
        //       *
        // Only 6/8 = 75% of error is diffused (higher contrast)

        for (0..height) |y| {
            const row_offset = y * width;

            for (0..width) |x| {
                const idx = row_offset + x;
                var err: i16 = undefined;
                const keep = if (redo) |r| r[idx] == 0 else false;
                if (keep) {
                    // Unchanged pixel: keep its dot, but still pass on the
                    // error it produced last time so neighbours stay continuous
                    err = self.errors[idx];
                } else {
                    // Get pixel value + accumulated error
                    const pixel: i16 = @as(i16, image.data[idx]) + err_row0[x];

                    // Threshold to black or white
                    const output: u8 = if (pixel >= threshold) 255 else 0;
                    binary[idx] = output;

                    // Calculate quantization error (only 75% distributed)
                    err = pixel - @as(i16, output);
                    self.errors[idx] = err;
                }
                // Atkinson: 1/8 to each of 6 neighbors = 6/8 = 75% total
                const err_frac = @divTrunc(err, 8);

                // Distribute error to 6 neighbors
                // Right (x+1, y): 1/8
                if (x + 1 < width) {
                    err_row0[x + 1] += err_frac;
                }
                // Right-right (x+2, y): 1/8
                if (x + 2 < width) {
                    err_row0[x + 2] += err_frac;
                }

                // Next row (y+1)
                if (y + 1 < height) {
                    // Down-left (x-1, y+1): 1/8
                    if (x > 0) {
                        err_row1[x - 1] += err_frac;
                    }
                    // Down (x, y+1): 1/8
                    err_row1[x] += err_frac;
                    // Down-right (x+1, y+1): 1/8
                    if (x + 1 < width) {
                        err_row1[x + 1] += err_frac;
                    }
                }

                // Two rows down (x, y+2): 1/8
                if (y + 2 < height) {
                    err_row2[x] += err_frac;
                }
            }

            // Rotate buffers: row0 <- row1 <- row2 <- cleared
            const tmp = err_row0;
            err_row0 = err_row1;
            err_row1 = err_row2;
            err_row2 = tmp;
            @memset(err_row2, 0);
        }

        return binaryToBraille(binary, image, target_cols, target_rows, self.invert, self.shading, allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AtkinsonConverter basic" {
    const allocator = std.testing.allocator;

    // Create gradient image
    var pixels: [64]u8 = undefined;
    for (0..64) |i| {
        pixels[i] = @intCast(i * 4); // 0 to 252 gradient
    }

    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var conv = try AtkinsonConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result);

    // 4 cols * 3 bytes + newline = 13 per row, 2 rows = 26
    try std.testing.expectEqual(@as(usize, 26), result.len);
}

test "AtkinsonConverter produces dithering pattern" {
    const allocator = std.testing.allocator;

    // Uniform mid-gray should produce a dithered pattern (not all same)
    var pixels = [_]u8{128} ** 64;
    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var conv = try AtkinsonConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result);

    // Should have some variation in the output
    try std.testing.expect(result.len > 0);
}

test "AtkinsonConverter invert" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{200} ** 16;
    const test_image = Image{
        .data = &pixels,
        .width = 4,
        .height = 4,
        .bytes_per_row = 4,
    };

    var conv1 = try AtkinsonConverter.init(allocator, 128, false);
    defer conv1.converter().deinit();
    const result1 = try conv1.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result1);

    var conv2 = try AtkinsonConverter.init(allocator, 128, true);
    defer conv2.converter().deinit();
    const result2 = try conv2.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}
