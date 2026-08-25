//! Converter module - aggregates all image-to-Braille conversion algorithms
//!
//! Available converters:
//! - EdgeConverter: Gradient-based edge detection
//! - AtkinsonConverter: Atkinson dithering (75% error diffusion, high contrast)
//! - FloydSteinbergConverter: Floyd-Steinberg dithering (100% error diffusion, smooth)
//! - BlueNoiseConverter: Blue noise threshold dithering (organic, pattern-free)
//! - BayerConverter: Bayer ordered dithering (fast, retro crosshatch pattern)

// Re-export the common interface
pub const Converter = @import("converters/common").Converter;
pub const Image = @import("converters/common").Image;
pub const Shading = @import("converters/common").Shading;

// Re-export converters
pub const EdgeConverter = @import("converters/edge").EdgeConverter;
pub const AtkinsonConverter = @import("converters/atkinson").AtkinsonConverter;
pub const FloydSteinbergConverter = @import("converters/floyd_steinberg").FloydSteinbergConverter;
pub const BlueNoiseConverter = @import("converters/blue_noise").BlueNoiseConverter;
pub const BayerConverter = @import("converters/bayer").BayerConverter;

// Re-export utilities that might be useful externally
pub const common = @import("converters/common");

test {
    // Run tests from all submodules
    @import("std").testing.refAllDecls(@This());
    _ = @import("converters/common");
    _ = @import("converters/edge");
    _ = @import("converters/atkinson");
    _ = @import("converters/floyd_steinberg");
    _ = @import("converters/blue_noise");
    _ = @import("converters/bayer");
}
