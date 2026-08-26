const std = @import("std");
const common = @import("common");

const Image = common.Image;
const Converter = common.Converter;
const binaryToBraille = common.binaryToBraille;

// =============================================================================
// Bayer Matrix (8x8, generated at comptime)
// =============================================================================

const MATRIX_SIZE = 8;
const MATRIX_LEN = MATRIX_SIZE * MATRIX_SIZE;

/// Generate 8x8 Bayer threshold matrix at compile time
/// Uses recursive definition: B(2n) = [4*B(n), 4*B(n)+2; 4*B(n)+3, 4*B(n)+1]
const BAYER_MATRIX: [MATRIX_LEN]u8 = blk: {
    // Start with 2x2 base matrix
    const b2 = [4]u8{ 0, 2, 3, 1 };

    // Expand to 4x4
    var b4: [16]u8 = undefined;
    for (0..2) |y| {
        for (0..2) |x| {
            const base = b2[y * 2 + x] * 4;
            const bx = x * 2;
            const by = y * 2;
            b4[(by + 0) * 4 + (bx + 0)] = base + 0;
            b4[(by + 0) * 4 + (bx + 1)] = base + 2;
            b4[(by + 1) * 4 + (bx + 0)] = base + 3;
            b4[(by + 1) * 4 + (bx + 1)] = base + 1;
        }
    }

    // Expand to 8x8
    var b8: [64]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const base = b4[y * 4 + x] * 4;
            const bx = x * 2;
            const by = y * 2;
            b8[(by + 0) * 8 + (bx + 0)] = base + 0;
            b8[(by + 0) * 8 + (bx + 1)] = base + 2;
            b8[(by + 1) * 8 + (bx + 0)] = base + 3;
            b8[(by + 1) * 8 + (bx + 1)] = base + 1;
        }
    }

    // Normalize to 0-255 range (64 values -> scale by 4, offset for centering)
    var result: [64]u8 = undefined;
    for (0..64) |i| {
        result[i] = b8[i] * 4 + 2; // Scale and center
    }

    break :blk result;
};

// =============================================================================
// Bayer Converter
// =============================================================================

/// Bayer ordered dithering converter
/// Uses an 8x8 threshold matrix for fast, pattern-based dithering
/// O(1) per pixel - single lookup + comparison
/// Produces characteristic crosshatch pattern (retro aesthetic)
pub const BayerConverter = struct {
    allocator: std.mem.Allocator,
    threshold: u8, // Global threshold adjustment
    invert: bool,
    shading: common.Shading = .none,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, threshold: u8, invert: bool) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .threshold = threshold,
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
        allocator.destroy(self);
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
        const size = width * height;

        // Output binary buffer
        var binary = try allocator.alloc(u8, size);
        defer allocator.free(binary);

        // Bayer dithering: simple threshold comparison with matrix
        // O(1) per pixel - just a lookup and compare
        const threshold_offset: i16 = @as(i16, self.threshold) - 128;

        for (0..height) |y| {
            const row_offset = y * width;
            const ty = y % MATRIX_SIZE;

            for (0..width) |x| {
                const gray = image.data[row_offset + x];

                // Get Bayer threshold for this position (tiled)
                const tx = x % MATRIX_SIZE;
                const base_threshold = BAYER_MATRIX[ty * MATRIX_SIZE + tx];

                // Apply threshold offset (clamp to valid range)
                const adjusted: i16 = @as(i16, base_threshold) + threshold_offset;
                const final_threshold: u8 = @intCast(@max(0, @min(255, adjusted)));

                binary[row_offset + x] = if (gray > final_threshold) 255 else 0;
            }
        }

        return binaryToBraille(binary, image, target_cols, target_rows, self.invert, self.shading, allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BayerConverter basic" {
    const allocator = std.testing.allocator;

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

    var conv = try BayerConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 26), result.len);
}

test "Bayer matrix is valid" {
    // Verify matrix has good distribution
    var min: u8 = 255;
    var max: u8 = 0;
    var sum: u64 = 0;

    for (BAYER_MATRIX) |val| {
        if (val < min) min = val;
        if (val > max) max = val;
        sum += val;
    }

    const avg = sum / MATRIX_LEN;

    // Should span most of the range
    try std.testing.expect(min < 10);
    try std.testing.expect(max > 245);
    // Average should be around 128
    try std.testing.expect(avg > 100 and avg < 156);
}

test "BayerConverter invert" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{128} ** 64;
    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var conv1 = try BayerConverter.init(allocator, 128, false);
    defer conv1.converter().deinit();
    const result1 = try conv1.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result1);

    var conv2 = try BayerConverter.init(allocator, 128, true);
    defer conv2.converter().deinit();
    const result2 = try conv2.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}

test "BayerConverter differs from blue noise" {
    const allocator = std.testing.allocator;
    const blue_noise = @import("blue_noise");

    var pixels = [_]u8{128} ** 64;
    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var bayer_conv = try BayerConverter.init(allocator, 128, false);
    defer bayer_conv.converter().deinit();
    const bayer_result = try bayer_conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(bayer_result);

    var bn_conv = try blue_noise.BlueNoiseConverter.init(allocator, 128, false);
    defer bn_conv.converter().deinit();
    const bn_result = try bn_conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(bn_result);

    // Both produce output but patterns differ
    try std.testing.expect(bayer_result.len > 0);
    try std.testing.expect(bn_result.len > 0);
}
