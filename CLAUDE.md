# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

`termicam` is a terminal-based camera viewer written in Zig that captures frames from a macOS camera and renders them as Braille patterns in the terminal. It uses Objective-C++ for camera integration with AVFoundation and implements real-time ASCII art rendering with edge detection.

## Build System & Commands

This project uses Zig's build system. Minimum Zig version: **0.16.0**

**Build and run:**
```bash
zig build run              # Build and run the application
zig build                  # Build only (output to zig-out/)
zig build test             # Run all tests
zig build --help           # Show all build options
```

**Build-time configuration options:**
```bash
# Capture strategy (default: pipelined)
zig build run -Dstrategy=direct      # Blocking capture
zig build run -Dstrategy=pipelined   # Double-buffered background thread

# Edge detection threshold 0-255 (default: 2, lower = more sensitive)
zig build run -Dedge-threshold=50

# Invert Braille output (default: false)
zig build run -Dinvert=true

# Camera warmup frames (default: 3)
zig build run -Dwarmup-frames=5
```

**Development:**
- Pass arguments to the app: `zig build run -- arg1 arg2`
- Build with specific optimization: `zig build -Doptimize=ReleaseFast`
- Build for specific target: `zig build -Dtarget=aarch64-macos`

## Architecture

### Module Structure

The project is organized as a library module (`termicam`) plus an executable:

- **Library module** (`src/root.zig`): Exposes public API that consumers can import
- **Executable** (`src/main.zig`): CLI application that imports and uses the library module

### Core Components

**Camera System (Native Integration)**
- `deps/camera_wrapper.h/mm`: Objective-C++ wrapper around AVFoundation (macOS camera API)
- `src/camera.zig`: Zig FFI layer that wraps the C API using `@cImport` and `@cInclude`
- Provides blocking frame capture with grayscale image output
- The build system links against AVFoundation, CoreMedia, CoreVideo, and Foundation frameworks

**Rendering Pipeline**
- `src/ascii.zig`: Pluggable converter interface for ASCII/Braille rendering
  - `Converter`: Generic interface with vtable pattern for multiple rendering backends
  - `BrailleConverter`: Main implementation that converts images to Braille patterns
  - Uses edge detection (gradient-based) rendering
  - Each Braille character represents a 2x4 pixel grid (Unicode U+2800-U+28FF)
- `src/term.zig`: Terminal utilities (size detection via ioctl, ANSI escape codes, aspect ratio calculation)

**Main Loop** (`src/main.zig`)
- Gets terminal dimensions
- Initializes camera with warmup frames for auto-exposure
- Continuous loop: capture frame -> convert to Braille -> render with FPS stats
- Uses buffered stdout for performance
- Supports two capture strategies:
  - **DirectCapture**: Simple blocking capture (original implementation)
  - **PipelinedCapture**: Double-buffered background thread for higher FPS

### Key Design Patterns

**FFI Bridge**: C wrapper (Objective-C++) -> Zig bindings -> Zig application
- Camera implementation is in Objective-C++ due to AVFoundation requirements
- C API provides clean boundary between Objective-C++ and Zig
- Compiled with `-ObjC++ -fno-objc-arc` flags

**Pluggable Rendering**: Generic `Converter` interface allows swapping rendering algorithms
- Uses vtable pattern (`ptr: *anyopaque` + `vtable: *const VTable`)
- Currently implements edge detection mode
- Easy to add new rendering backends (e.g., dithering)

**Pluggable Frame Sources**: Generic `FrameSource` interface allows swapping capture strategies
- Uses vtable pattern for different capture implementations
- DirectCapture: Simple blocking calls
- PipelinedCapture: Background thread with double buffering for improved performance

**Aspect Ratio Preservation**: `term.calculateBrailleDimensions()` maintains 1:1 pixel aspect ratio
- Takes image dimensions and terminal size
- Calculates optimal output that fits within terminal bounds

### Module Dependency Hierarchy

The build system creates a hierarchy of modules (build.zig:47-92):
1. **camera** (base module): No dependencies, wraps C/Objective-C++ code
2. **ascii** and **term**: Both depend on camera module
3. **termicam** (main library): Aggregates all submodules and re-exports them
4. **executable**: Depends on termicam library module

Each module has its own test suite that runs with `zig build test`.

## Platform-Specific Notes

**macOS only**: This project relies on AVFoundation and requires macOS. The build configuration links against macOS frameworks (build.zig:60-63).

**Objective-C++ Requirement**: The camera wrapper uses Objective-C++ because AVFoundation is an Objective-C framework. The `.mm` extension and specific compiler flags (`-ObjC++ -fno-objc-arc`) are required.

**Terminal Dependencies**: Uses Unix ioctl (TIOCGWINSZ) for terminal size detection and ANSI escape codes for rendering.
