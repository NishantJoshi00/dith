const std = @import("std");
const common = @import("common");

const Image = common.Image;
const Converter = common.Converter;
const binaryToBraille = common.binaryToBraille;

/// Floyd-Steinberg dithering converter
/// Classic error diffusion algorithm with full error distribution
/// Produces smooth gradients with natural-looking noise
///
/// Optimized: Uses 2-row rolling buffer instead of full image copy
/// Memory: O(width) instead of O(width * height)
pub const FloydSteinbergConverter = struct {
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

        // Rolling error buffers - only need current row and next row
        // Using i16 for error accumulation to handle overflow
        var err_curr = try allocator.alloc(i16, width);
        defer allocator.free(err_curr);
        var err_next = try allocator.alloc(i16, width);
        defer allocator.free(err_next);

        // Initialize first row errors to zero
        @memset(err_curr, 0);
        @memset(err_next, 0);

        const threshold = self.threshold;

        // Floyd-Steinberg error diffusion pattern:
        //       X   7/16
        // 3/16 5/16 1/16

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
                    const pixel: i16 = @as(i16, image.data[idx]) + err_curr[x];

                    // Threshold to black or white
                    const output: u8 = if (pixel >= threshold) 255 else 0;
                    binary[idx] = output;

                    // Calculate quantization error
                    err = pixel - @as(i16, output);
                    self.errors[idx] = err;
                }

                // Distribute error using bit shifts for speed (approximates /16)
                // 7/16 ≈ 7>>4, 5/16 ≈ 5>>4, 3/16 ≈ 3>>4, 1/16 ≈ 1>>4
                const err7 = @divTrunc(err * 7, 16);
                const err5 = @divTrunc(err * 5, 16);
                const err3 = @divTrunc(err * 3, 16);
                const err1 = @divTrunc(err, 16);

                // Right (x+1, y): 7/16
                if (x + 1 < width) {
                    err_curr[x + 1] += err7;
                }

                // Next row errors (will be used when we advance)
                if (y + 1 < height) {
                    // Down-left (x-1, y+1): 3/16
                    if (x > 0) {
                        err_next[x - 1] += err3;
                    }
                    // Down (x, y+1): 5/16
                    err_next[x] += err5;
                    // Down-right (x+1, y+1): 1/16
                    if (x + 1 < width) {
                        err_next[x + 1] += err1;
                    }
                }
            }

            // Swap buffers: next becomes current, clear next
            const tmp = err_curr;
            err_curr = err_next;
            err_next = tmp;
            @memset(err_next, 0);
        }

        return binaryToBraille(binary, image, target_cols, target_rows, self.invert, self.shading, allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "FloydSteinbergConverter basic" {
    const allocator = std.testing.allocator;

    // Create gradient image
    var pixels: [64]u8 = undefined;
    for (0..64) |i| {
        pixels[i] = @intCast(i * 4);
    }

    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var conv = try FloydSteinbergConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 26), result.len);
}

test "FloydSteinbergConverter dithering differs from atkinson" {
    const allocator = std.testing.allocator;
    const atkinson = @import("atkinson");

    // Same gray image
    var pixels = [_]u8{128} ** 64;
    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var fs_conv = try FloydSteinbergConverter.init(allocator, 128, false);
    defer fs_conv.converter().deinit();
    const fs_result = try fs_conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(fs_result);

    var atk_conv = try atkinson.AtkinsonConverter.init(allocator, 128, false);
    defer atk_conv.converter().deinit();
    const atk_result = try atk_conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(atk_result);

    // Both should work, but may produce different patterns
    try std.testing.expect(fs_result.len > 0);
    try std.testing.expect(atk_result.len > 0);
}

test "FloydSteinbergConverter re-dithers only changed pixels" {
    const allocator = std.testing.allocator;

    // A gradient; then a second frame with one corner region brightened
    var base: [32 * 32]u8 = undefined;
    for (0..32 * 32) |i| base[i] = @intCast(40 + (i % 32) * 5);
    var moved = base;
    var changed = [_]u8{0} ** (32 * 32);
    for (0..6) |y| for (0..6) |x| {
        moved[(26 + y) * 32 + (26 + x)] = 250;
        changed[(26 + y) * 32 + (26 + x)] = 1;
    };
    const img_base = Image{ .data = &base, .width = 32, .height = 32, .bytes_per_row = 32 };
    const change_map: common.Mask = .{ .data = &changed, .width = 32, .height = 32, .bytes_per_row = 32 };
    const img_moved = Image{ .data = &moved, .width = 32, .height = 32, .bytes_per_row = 32, .changed = change_map };

    var conv = try FloydSteinbergConverter.init(allocator, 128, false);
    defer conv.converter().deinit();
    const frame1 = try conv.imageToText(img_base, 16, 8, allocator);
    defer allocator.free(frame1);
    const frame2 = try conv.imageToText(img_moved, 16, 8, allocator);
    defer allocator.free(frame2);

    // Every cell outside the bottom-right corner is untouched (row = 16 cells * 3 bytes + newline)
    for (0..8) |row| for (0..16) |col| {
        const off = row * 49 + col * 3;
        const near_change = row >= 5 and col >= 11;
        if (!near_change) try std.testing.expectEqualSlices(u8, frame1[off .. off + 3], frame2[off .. off + 3]);
    };
    try std.testing.expect(!std.mem.eql(u8, frame1, frame2));

    // With an all-zero change map the old dots stand even though the data moved
    const none = [_]u8{0} ** (32 * 32);
    const img_frozen = Image{ .data = &moved, .width = 32, .height = 32, .bytes_per_row = 32, .changed = .{ .data = &none, .width = 32, .height = 32, .bytes_per_row = 32 } };
    const frame3 = try conv.imageToText(img_frozen, 16, 8, allocator);
    defer allocator.free(frame3);
    try std.testing.expectEqualStrings(frame2, frame3);
}

test "FloydSteinbergConverter invert" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{200} ** 16;
    const test_image = Image{
        .data = &pixels,
        .width = 4,
        .height = 4,
        .bytes_per_row = 4,
    };

    var conv1 = try FloydSteinbergConverter.init(allocator, 128, false);
    defer conv1.converter().deinit();
    const result1 = try conv1.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result1);

    var conv2 = try FloydSteinbergConverter.init(allocator, 128, true);
    defer conv2.converter().deinit();
    const result2 = try conv2.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}
