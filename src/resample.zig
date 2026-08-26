//! Downsampling to the dot grid. Dithering only reproduces tone when every
//! dot it produces is shown, so the frame is box-filtered to exactly the
//! Braille dot resolution before anything else looks at it.
const std = @import("std");
const types = @import("types");

/// Half-open source span covered by one destination pixel along one axis
const Span = struct { start: u32, end: u32 };

fn spans(allocator: std.mem.Allocator, dst_len: u32, src_len: u32) ![]Span {
    const out = try allocator.alloc(Span, dst_len);
    for (out, 0..) |*span, i| {
        var start: u32 = @intCast(i * src_len / dst_len);
        var end: u32 = @intCast((i + 1) * src_len / dst_len);
        if (start >= src_len) start = src_len - 1;
        if (end > src_len) end = src_len;
        if (end <= start) end = start + 1;
        span.* = .{ .start = start, .end = end };
    }
    return out;
}

/// Box-average one 8-bit plane with `channels` interleaved samples per pixel
fn boxFilter(
    allocator: std.mem.Allocator,
    src: []const u8,
    src_width: u32,
    src_height: u32,
    src_bytes_per_row: u32,
    channels: u32,
    dst: []u8,
    dst_width: u32,
    dst_height: u32,
) !void {
    const xs = try spans(allocator, dst_width, src_width);
    defer allocator.free(xs);
    const ys = try spans(allocator, dst_height, src_height);
    defer allocator.free(ys);

    for (ys, 0..) |yspan, dy| {
        const dst_row = dst[dy * dst_width * channels ..];
        for (xs, 0..) |xspan, dx| {
            var sums = [_]u32{0} ** 4;
            for (yspan.start..yspan.end) |sy| {
                const row = src[sy * src_bytes_per_row ..];
                for (xspan.start..xspan.end) |sx| {
                    for (0..channels) |ch| sums[ch] += row[sx * channels + ch];
                }
            }
            const count = (yspan.end - yspan.start) * (xspan.end - xspan.start);
            for (0..channels) |ch| {
                dst_row[dx * channels + ch] = @intCast((sums[ch] + count / 2) / count);
            }
        }
    }
}

/// Owns the downsampled planes and reuses them frame to frame
pub const Frame = struct {
    allocator: std.mem.Allocator,
    luma: []u8 = &.{},
    chroma: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    chroma_width: u32 = 0,
    chroma_height: u32 = 0,
    has_chroma: bool = false,

    pub fn init(allocator: std.mem.Allocator) Frame {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.luma);
        self.allocator.free(self.chroma);
        self.* = .{ .allocator = self.allocator };
    }

    fn ensure(self: *Frame, width: u32, height: u32) !void {
        const cw = (width + 1) / 2;
        const ch = (height + 1) / 2;
        if (self.luma.len != width * height) {
            self.allocator.free(self.luma);
            self.luma = &.{};
            self.luma = try self.allocator.alloc(u8, width * height);
        }
        if (self.chroma.len != cw * ch * 2) {
            self.allocator.free(self.chroma);
            self.chroma = &.{};
            self.chroma = try self.allocator.alloc(u8, cw * ch * 2);
        }
        self.width = width;
        self.height = height;
        self.chroma_width = cw;
        self.chroma_height = ch;
    }

    /// Downsample `src` to exactly width x height. Luma and chroma are box
    /// averaged; the depth mask is passed through (it scales on lookup).
    /// The returned image views this frame's buffers.
    pub fn downsample(self: *Frame, src: types.Image, width: u32, height: u32) !types.Image {
        try self.ensure(width, height);
        try boxFilter(self.allocator, src.data, src.width, src.height, src.bytes_per_row, 1, self.luma, width, height);

        self.has_chroma = false;
        if (src.chroma) |c| {
            try boxFilter(self.allocator, c.data, c.width, c.height, c.bytes_per_row, 2, self.chroma, self.chroma_width, self.chroma_height);
            self.has_chroma = true;
        }

        return .{
            .data = self.luma,
            .width = width,
            .height = height,
            .bytes_per_row = width,
            .chroma = if (self.has_chroma) .{
                .data = self.chroma,
                .width = self.chroma_width,
                .height = self.chroma_height,
                .bytes_per_row = self.chroma_width * 2,
            } else null,
            .mask = src.mask,
        };
    }
};

// =============================================================================
// Tests
// =============================================================================

test "downsample box-averages luma exactly" {
    const allocator = std.testing.allocator;
    // 4x4 -> 2x2: each output is the mean of a 2x2 block
    const px = [_]u8{
        0,   0,   100, 100,
        0,   0,   100, 100,
        200, 200, 50,  50,
        200, 200, 50,  50,
    };
    const src = types.Image{ .data = &px, .width = 4, .height = 4, .bytes_per_row = 4 };
    var frame = Frame.init(allocator);
    defer frame.deinit();
    const out = try frame.downsample(src, 2, 2);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 100, 200, 50 }, out.data);
    try std.testing.expectEqual(@as(u32, 2), out.bytes_per_row);
    try std.testing.expect(out.chroma == null);
}

test "downsample handles non-integer ratios and interleaved chroma" {
    const allocator = std.testing.allocator;
    // 6x3 luma gradient -> 4x2; chroma 3x2 (Cb,Cr pairs) -> 2x1
    var px: [6 * 3]u8 = undefined;
    for (0..18) |i| px[i] = @intCast(i * 10);
    const chroma = [_]u8{
        100, 200, 110, 210, 120, 220,
        100, 200, 110, 210, 120, 220,
    };
    const src = types.Image{
        .data = &px,
        .width = 6,
        .height = 3,
        .bytes_per_row = 6,
        .chroma = .{ .data = &chroma, .width = 3, .height = 2, .bytes_per_row = 6 },
    };
    var frame = Frame.init(allocator);
    defer frame.deinit();
    const out = try frame.downsample(src, 4, 2);
    try std.testing.expectEqual(@as(u32, 4), out.width);
    try std.testing.expectEqual(@as(u32, 2), out.height);
    // Tone is preserved: first output pixel averages columns 0 (row 0) -> 0
    try std.testing.expectEqual(@as(u8, 0), out.data[0]);
    // Last output pixel averages columns 4..5 of rows 1..2 -> (100+110+160+170)/4 = 135
    try std.testing.expectEqual(@as(u8, 135), out.data[7]);
    const ch = out.chroma.?;
    try std.testing.expectEqual(@as(u32, 2), ch.width);
    try std.testing.expectEqual(@as(u32, 1), ch.height);
    // Cb over columns 0 (span 0..1) = 100, Cr = 200; second: columns 1..2 -> 115, 215
    try std.testing.expectEqualSlices(u8, &[_]u8{ 100, 200, 115, 215 }, ch.data[0..4]);
}

test "downsample passes the mask through" {
    const allocator = std.testing.allocator;
    const px = [_]u8{0} ** 16;
    const mask = [_]u8{ 255, 0, 0, 255 };
    const src = types.Image{ .data = &px, .width = 4, .height = 4, .bytes_per_row = 4, .mask = .{ .data = &mask, .width = 2, .height = 2, .bytes_per_row = 2 } };
    var frame = Frame.init(allocator);
    defer frame.deinit();
    const out = try frame.downsample(src, 2, 2);
    try std.testing.expectEqual(@as(u8, 255), out.mask.?.at(0, 0, 2, 2));
    try std.testing.expectEqual(@as(u8, 0), out.mask.?.at(1, 0, 2, 2));
}
