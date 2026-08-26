const std = @import("std");

/// Chroma plane: interleaved Cb,Cr pairs at half resolution (4:2:0)
pub const Chroma = struct {
    data: []const u8,
    width: u32,
    height: u32,
    bytes_per_row: u32,
};

/// Subject mask 0-255 (255 = confidently the person), at its own resolution
pub const Mask = struct {
    data: []const u8,
    width: u32,
    height: u32,
    bytes_per_row: u32,

    /// Mask value at an image pixel, scaled from the mask's own resolution
    pub inline fn at(self: Mask, x: u32, y: u32, image_width: u32, image_height: u32) u8 {
        const mx = @min(self.width - 1, x * self.width / image_width);
        const my = @min(self.height - 1, y * self.height / image_height);
        return self.data[my * self.bytes_per_row + mx];
    }
};

/// Image data (grayscale luma, plus optional chroma and subject mask)
pub const Image = struct {
    data: []const u8,
    width: u32,
    height: u32,
    bytes_per_row: u32,
    chroma: ?Chroma = null,
    mask: ?Mask = null,
    /// Which pixels changed since the previous frame (same geometry as `data`,
    /// non-zero = changed). Null means treat every pixel as changed.
    changed: ?Mask = null,

    /// Get pixel value at (x, y)
    /// Inline for performance in tight rendering loops
    pub inline fn getPixel(self: Image, x: u32, y: u32) u8 {
        std.debug.assert(x < self.width);
        std.debug.assert(y < self.height);
        const offset = y * self.bytes_per_row + x;
        return self.data[offset];
    }
};

/// Supported image formats
pub const ImageFormat = enum {
    png,
    jpeg,
    bmp,
    unknown,
};

/// 8-bit RGB triple
pub const Rgb = [3]u8;

/// The terminal's own colors: shading ranges run from `bg` to `fg`
pub const Theme = struct {
    fg: Rgb,
    bg: Rgb,
    /// The 16 ANSI colors, used by the 16-color palette
    colors: [16]Rgb,
};
