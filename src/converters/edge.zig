const std = @import("std");
const common = @import("common");

const Image = common.Image;
const Converter = common.Converter;
const BRAILLE_DOT_POSITIONS = common.BRAILLE_DOT_POSITIONS;
const encodeBraille = common.encodeBraille;
const absDiff = common.absDiff;

/// Edge detection converter using gradient-based rendering
/// Places Braille dots where edges (gradients) are detected in the image
pub const EdgeConverter = struct {
    allocator: std.mem.Allocator,
    threshold: u8, // Threshold for edge detection gradient (0-255)
    invert: bool, // Invert output
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

    /// Get generic Converter interface
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

    /// Convert image to Braille text using edge detection
    pub fn imageToText(
        self: *Self,
        image: Image,
        target_cols: u32,
        target_rows: u32,
        allocator: std.mem.Allocator,
    ) ![]u8 {
        const sampler = EdgeSampler{
            .conv = self,
            .image = image,
            .gate = common.MaskGate.from(image, self.shading),
            // Scaling factors from output space to source image space
            .scale_x = @as(f32, @floatFromInt(image.width)) / @as(f32, @floatFromInt(target_cols * 2)),
            .scale_y = @as(f32, @floatFromInt(image.height)) / @as(f32, @floatFromInt(target_rows * 4)),
        };
        return encodeBraille(sampler, image, target_cols, target_rows, self.invert, self.shading, allocator);
    }

    /// Produces the 2x4 dot pattern for one cell using edge detection
    const EdgeSampler = struct {
        conv: *Self,
        image: Image,
        scale_x: f32,
        scale_y: f32,
        gate: ?common.MaskGate,

        pub inline fn pattern(s: EdgeSampler, col: u32, row: u32) u8 {
            var bits: u8 = 0;

            const base_out_x = col * 2;
            const base_out_y = row * 4;

            for (BRAILLE_DOT_POSITIONS, 0..) |pos, i| {
                const out_x = base_out_x + pos[0];
                const out_y = base_out_y + pos[1];

                const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_x)) * s.scale_x));
                const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(out_y)) * s.scale_y));

                if (src_x < s.image.width and src_y < s.image.height) {
                    var draw = s.conv.shouldDrawDot(s.image, src_x, src_y);
                    if (draw and s.gate != null) draw = s.gate.?.allows(src_x, src_y, s.image.width, s.image.height);
                    if (draw) {
                        bits |= @as(u8, 1) << @intCast(i);
                    }
                }
            }

            return bits;
        }
    };

    /// Determine if a dot should be drawn using edge detection
    /// Places dots where gradients/edges are detected
    fn shouldDrawDot(self: *Self, image: Image, x: u32, y: u32) bool {
        const center = image.getPixel(x, y);
        const width = image.width;
        const height = image.height;

        var gradient: u32 = 0;
        var count: u32 = 0;

        // Check 4-connected neighbors
        if (x > 0) {
            gradient += absDiff(center, image.getPixel(x - 1, y));
            count += 1;
        }
        if (x + 1 < width) {
            gradient += absDiff(center, image.getPixel(x + 1, y));
            count += 1;
        }
        if (y > 0) {
            gradient += absDiff(center, image.getPixel(x, y - 1));
            count += 1;
        }
        if (y + 1 < height) {
            gradient += absDiff(center, image.getPixel(x, y + 1));
            count += 1;
        }

        const avg_gradient = gradient / count;
        const result = avg_gradient > self.threshold;
        return if (self.invert) !result else result;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "EdgeConverter basic" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{
        255, 255,
        0,   0,
        255, 255,
        0,   0,
    };

    const test_image = Image{
        .data = &pixels,
        .width = 2,
        .height = 4,
        .bytes_per_row = 2,
    };

    var conv = try EdgeConverter.init(allocator, 128, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 1, 1, allocator);
    defer allocator.free(result);

    try std.testing.expect(result.len == 4); // 3 bytes UTF-8 + 1 newline
    try std.testing.expectEqual(@as(u8, '\n'), result[3]);
}

test "EdgeConverter edge detection" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{
        0, 0, 255, 255,
        0, 0, 255, 255,
        0, 0, 255, 255,
        0, 0, 255, 255,
    };

    const test_image = Image{
        .data = &pixels,
        .width = 4,
        .height = 4,
        .bytes_per_row = 4,
    };

    var conv = try EdgeConverter.init(allocator, 50, false);
    defer conv.converter().deinit();

    const result = try conv.imageToText(test_image, 2, 1, allocator);
    defer allocator.free(result);

    try std.testing.expectEqual(@as(usize, 7), result.len);
    try std.testing.expectEqual(@as(u8, '\n'), result[6]);
}

test "EdgeConverter invert option" {
    const allocator = std.testing.allocator;

    var pixels = [_]u8{255} ** 8;
    const test_image = Image{
        .data = &pixels,
        .width = 2,
        .height = 4,
        .bytes_per_row = 2,
    };

    var conv1 = try EdgeConverter.init(allocator, 128, false);
    defer conv1.converter().deinit();
    const result1 = try conv1.imageToText(test_image, 1, 1, allocator);
    defer allocator.free(result1);

    var conv2 = try EdgeConverter.init(allocator, 128, true);
    defer conv2.converter().deinit();
    const result2 = try conv2.imageToText(test_image, 1, 1, allocator);
    defer allocator.free(result2);

    try std.testing.expect(!std.mem.eql(u8, result1, result2));
}
