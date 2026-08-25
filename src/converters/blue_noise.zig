const std = @import("std");
const common = @import("common");

const Image = common.Image;
const Converter = common.Converter;
const binaryToBraille = common.binaryToBraille;

// =============================================================================
// Blue Noise Texture (64x64, generated at comptime)
// =============================================================================

const TEXTURE_SIZE = 64;
const TEXTURE_LEN = TEXTURE_SIZE * TEXTURE_SIZE;

/// Generate blue noise texture at compile time using interleaved gradient noise
/// This produces a high-quality threshold map with blue noise characteristics
const BLUE_NOISE_TEXTURE: [TEXTURE_LEN]u8 = blk: {
    @setEvalBranchQuota(100000);
    var texture: [TEXTURE_LEN]u8 = undefined;

    // Generate using interleaved gradient noise (Jorge Jimenez, Call of Duty)
    // This produces excellent blue-noise-like distribution
    for (0..TEXTURE_SIZE) |y| {
        for (0..TEXTURE_SIZE) |x| {
            const xf: f32 = @floatFromInt(x);
            const yf: f32 = @floatFromInt(y);

            // IGN formula: fract(52.9829189 * fract(0.06711056*x + 0.00583715*y))
            const dot = 0.06711056 * xf + 0.00583715 * yf;
            const fract1 = dot - @floor(dot);
            const scaled = 52.9829189 * fract1;
            const fract2 = scaled - @floor(scaled);

            // Convert to 0-255 range
            texture[y * TEXTURE_SIZE + x] = @intFromFloat(fract2 * 255.0);
        }
    }

    break :blk texture;
};

// =============================================================================
// Blue Noise Converter
// =============================================================================

/// Blue noise dithering converter
/// Uses a pre-computed blue noise threshold map for organic-looking dithering
/// O(1) per pixel - single lookup + comparison
pub const BlueNoiseConverter = struct {
    allocator: std.mem.Allocator,
    threshold: u8, // Global threshold adjustment (shifts the threshold map)
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

        // Blue noise dithering: simple threshold comparison
        // O(1) per pixel - just a lookup and compare
        const threshold_offset: i16 = @as(i16, self.threshold) - 128;

        for (0..height) |y| {
            for (0..width) |x| {
                const idx = y * width + x;
                const gray = image.data[idx];

                // Get blue noise threshold for this position (tiled)
                const tx = x % TEXTURE_SIZE;
                const ty = y % TEXTURE_SIZE;
                const base_threshold = BLUE_NOISE_TEXTURE[ty * TEXTURE_SIZE + tx];

                // Apply threshold offset (clamp to valid range)
                const adjusted: i16 = @as(i16, base_threshold) + threshold_offset;
                const final_threshold: u8 = @intCast(@max(0, @min(255, adjusted)));

                binary[idx] = if (gray > final_threshold) 255 else 0;
            }
        }

        return binaryToBraille(binary, image, target_cols, target_rows, self.invert, self.shading, allocator);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "BlueNoiseConverter basic" {
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

    var conv = try BlueNoiseConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 26), result.len);
}

test "BlueNoiseConverter texture is valid" {
    // Verify texture has good distribution (not all same value)
    var min: u8 = 255;
    var max: u8 = 0;
    var sum: u64 = 0;

    for (BLUE_NOISE_TEXTURE) |val| {
        if (val < min) min = val;
        if (val > max) max = val;
        sum += val;
    }

    const avg = sum / TEXTURE_LEN;

    // Should span most of the range
    try std.testing.expect(min < 20);
    try std.testing.expect(max > 235);
    // Average should be around 128
    try std.testing.expect(avg > 100 and avg < 156);
}

test "BlueNoiseConverter invert" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{128} ** 64;
    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    var conv1 = try BlueNoiseConverter.init(allocator, 128, false);
    defer conv1.converter().deinit();
    const result1 = try conv1.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result1);

    var conv2 = try BlueNoiseConverter.init(allocator, 128, true);
    defer conv2.converter().deinit();
    const result2 = try conv2.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}

test "BlueNoiseConverter threshold adjustment" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{128} ** 64;
    const test_image = Image{
        .data = &pixels,
        .width = 8,
        .height = 8,
        .bytes_per_row = 8,
    };

    // Low threshold = more dots
    var conv_low = try BlueNoiseConverter.init(allocator, 64, false);
    defer conv_low.converter().deinit();
    const result_low = try conv_low.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result_low);

    // High threshold = fewer dots
    var conv_high = try BlueNoiseConverter.init(allocator, 192, false);
    defer conv_high.converter().deinit();
    const result_high = try conv_high.imageToText(test_image, 4, 2, allocator);
    defer allocator.free(result_high);

    // Results should differ
    try std.testing.expect(!std.mem.eql(u8, result_low, result_high));
}
