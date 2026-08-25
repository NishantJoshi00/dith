//! By convention, root.zig is the root source file when making a library.
//! This module aggregates and re-exports all dith submodules.

// Import all submodules
pub const types = @import("types");
pub const camera = @import("camera");
pub const depth = @import("depth");
pub const converter = @import("converter");
pub const term = @import("term");
pub const cli = @import("cli");
pub const image = @import("image");
