const std = @import("std");
const Io = std.Io;
const dith = @import("dith");
const camera = dith.camera;
const converter = dith.converter;
const term = dith.term;
const cli = dith.cli;
const image = dith.image;
const builtin = @import("builtin");

/// Generic frame source interface for pluggable capture strategies
const FrameSource = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getNextFrame: *const fn (ptr: *anyopaque) camera.Image,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Get the next frame from this source
    pub fn getNextFrame(self: FrameSource) camera.Image {
        return self.vtable.getNextFrame(self.ptr);
    }

    /// Clean up frame source resources
    pub fn deinit(self: FrameSource) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Direct (blocking) frame capture - original implementation
const DirectCapture = struct {
    camera: *camera.Camera,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cam: *camera.Camera) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .camera = cam,
            .allocator = allocator,
        };
        return self;
    }

    pub fn frameSource(self: *Self) FrameSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getNextFrame = getNextFrameImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextFrameImpl(ptr: *anyopaque) camera.Image {
        const self: *Self = @ptrCast(@alignCast(ptr));
        // Note: In real usage this can fail, but interface doesn't support errors
        // Caller should handle warmup/opening before using DirectCapture
        return self.camera.captureFrame() catch unreachable;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

/// Double-buffered frame pipeline that captures frames on a background task
/// while the main thread processes previously captured frames.
const PipelinedCapture = struct {
    camera: *camera.Camera,
    allocator: std.mem.Allocator,
    io: Io,

    buffers: [2]OwnedImage,
    write_idx: usize,

    mutex: Io.Mutex,
    capture_task: Io.Future(void),
    should_stop: std.atomic.Value(bool),

    const OwnedImage = struct {
        data: []u8,
        width: u32,
        height: u32,
        bytes_per_row: u32,

        fn toImage(self: *const OwnedImage) camera.Image {
            return .{
                .data = self.data,
                .width = self.width,
                .height = self.height,
                .bytes_per_row = self.bytes_per_row,
            };
        }
    };

    const Self = @This();

    /// Initialize pipeline and start the background capture task
    pub fn init(allocator: std.mem.Allocator, io: Io, cam: *camera.Camera) !*Self {
        const pipeline = try allocator.create(Self);
        errdefer allocator.destroy(pipeline);

        // Capture initial frame to determine buffer dimensions
        const initial_frame = try cam.captureFrame();
        const buf_size = initial_frame.bytes_per_row * initial_frame.height;

        // Allocate double buffers
        const buf0 = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(buf0);
        const buf1 = try allocator.alloc(u8, buf_size);
        errdefer allocator.free(buf1);

        // Copy initial frame into first buffer
        @memcpy(buf0[0..initial_frame.data.len], initial_frame.data);

        pipeline.* = .{
            .camera = cam,
            .allocator = allocator,
            .io = io,
            .buffers = .{
                .{
                    .data = buf0,
                    .width = initial_frame.width,
                    .height = initial_frame.height,
                    .bytes_per_row = initial_frame.bytes_per_row,
                },
                .{
                    .data = buf1,
                    .width = initial_frame.width,
                    .height = initial_frame.height,
                    .bytes_per_row = initial_frame.bytes_per_row,
                },
            },
            .write_idx = 0,
            .mutex = .init,
            .should_stop = .init(false),
            .capture_task = undefined,
        };

        // Start background capture task. `concurrent` (not `async`) because the
        // loop must actually run in parallel with the render loop.
        pipeline.capture_task = try io.concurrent(captureLoop, .{pipeline});

        return pipeline;
    }

    /// Get FrameSource interface
    pub fn frameSource(self: *Self) FrameSource {
        return .{
            .ptr = self,
            .vtable = &.{
                .getNextFrame = getNextFrameImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn getNextFrameImpl(ptr: *anyopaque) camera.Image {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Read from the buffer that's NOT being written to
        const read_idx = 1 - self.write_idx;
        return self.buffers[read_idx].toImage();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.should_stop.store(true, .release);
        self.capture_task.await(self.io);

        self.allocator.free(self.buffers[0].data);
        self.allocator.free(self.buffers[1].data);
        self.allocator.destroy(self);
    }

    /// Background task that continuously captures frames
    fn captureLoop(self: *Self) void {
        while (!self.should_stop.load(.acquire)) {
            // Capture frame (may fail, just continue to next iteration)
            const frame = self.camera.captureFrame() catch continue;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const idx = self.write_idx;
            const buf = &self.buffers[idx];

            // Copy frame data into our buffer
            @memcpy(buf.data[0..frame.data.len], frame.data);
            buf.width = frame.width;
            buf.height = frame.height;
            buf.bytes_per_row = frame.bytes_per_row;

            // Swap: this buffer is now ready, start writing to the other
            self.write_idx = 1 - self.write_idx;
        }
    }
};

/// Frame capture strategy selection
const CaptureStrategy = enum {
    direct, // Simple blocking capture (no pipelining)
    pipelined, // Double-buffered background task
};

/// Initialize converter based on CLI mode selection
fn initConverter(mode: cli.Mode, allocator: std.mem.Allocator) !converter.Converter {
    return switch (mode) {
        .edge => |cfg| blk: {
            const conv = try converter.EdgeConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
        .atkinson => |cfg| blk: {
            const conv = try converter.AtkinsonConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
        .floyd_steinberg => |cfg| blk: {
            const conv = try converter.FloydSteinbergConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
        .blue_noise => |cfg| blk: {
            const conv = try converter.BlueNoiseConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
        .bayer => |cfg| blk: {
            const conv = try converter.BayerConverter.init(allocator, cfg.threshold, cfg.invert);
            break :blk conv.converter();
        },
    };
}

/// Monotonic clock reading in nanoseconds
inline fn nowNs(io: Io) i96 {
    return Io.Timestamp.now(io, .awake).toNanoseconds();
}

inline fn nsToMs(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // Leak-checked debug allocator in Debug builds, libc malloc in release.
    const allocator = init.gpa;

    // Parse CLI arguments
    const args = cli.parse(io, init.minimal.args) catch |err| {
        cli.printErrorAndHelp(io, err);
        std.process.exit(1);
    } orelse {
        // Help was requested
        cli.printHelp(io);
        return;
    };

    // Get terminal size
    const term_size = try term.getTermSize();

    // Handle file source (static image, render once and exit)
    switch (args.source) {
        .file => |file_config| {
            var img = image.load(allocator, file_config.path) catch |err| {
                var buffer: [256]u8 = undefined;
                var writer = Io.File.stderr().writerStreaming(io, &buffer);
                const stderr = &writer.interface;
                const msg = switch (err) {
                    image.ImageError.LoadFailed => "error: failed to load image\n",
                    image.ImageError.OutOfMemory => "error: out of memory\n",
                };
                stderr.writeAll(msg) catch {};
                stderr.flush() catch {};
                std.process.exit(1);
            };
            defer img.deinit();

            // Initialize converter based on mode
            const conv = try initConverter(args.mode, allocator);
            defer conv.deinit();

            const frame = img.toImage();
            const dims = term.calculateBrailleDimensions(frame, term_size);
            const braille_text = try conv.convert(frame, dims.cols, dims.rows, allocator);
            defer allocator.free(braille_text);

            var stdout_buffer: [32768]u8 = undefined;
            var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
            const stdout = &stdout_writer.interface;

            try term.clearScreen(stdout);
            try stdout.writeAll(braille_text);
            try stdout.writeAll("\n");
            try stdout.flush();

            return;
        },
        .cam => {}, // Continue below
    }

    // Camera source
    const cam_config = args.source.cam;

    // Initialize camera
    var cam = try camera.Camera.init();
    defer cam.deinit();

    // Open camera
    try cam.open();
    defer cam.close();

    // Initialize converter based on mode
    const conv = try initConverter(args.mode, allocator);
    defer conv.deinit();

    // Warmup: Capture and discard frames to let camera auto-expose
    var i: u32 = 0;
    while (i < cam_config.warmup) : (i += 1) {
        _ = try cam.captureFrame();
    }

    // Initialize frame source based on CLI strategy configuration
    const source = switch (cam_config.strategy) {
        .direct => blk: {
            var direct = try DirectCapture.init(allocator, &cam);
            break :blk direct.frameSource();
        },
        .pipelined => blk: {
            var pipeline = try PipelinedCapture.init(allocator, io, &cam);
            break :blk pipeline.frameSource();
        },
    };
    defer source.deinit();

    // Setup buffered stdout writer (reused across frames)
    // Use larger buffer to accommodate full-screen Braille output (160x45 = ~22KB)
    var stdout_buffer: [32768]u8 = undefined;
    var stdout_writer = Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    // Per-frame scratch memory. Every frame's working buffers (binary image,
    // error rows, output text) come from here and are reclaimed with a single
    // reset, so steady state does zero malloc/free calls per frame.
    var frame_arena = std.heap.ArenaAllocator.init(allocator);
    defer frame_arena.deinit();

    // Target 60 FPS: 1/60 second = 16.666ms = 16,666,666 nanoseconds
    const target_frame_time_ns: i96 = 16_666_666;

    // Continuous frame loop
    while (true) {
        // Start timing
        const start_time = nowNs(io);

        _ = frame_arena.reset(.retain_capacity);
        const frame_allocator = frame_arena.allocator();

        // Get next frame (captured on the background task)
        const frame = source.getNextFrame();

        // Calculate output dimensions that fit within terminal bounds
        const dims = term.calculateBrailleDimensions(frame, term_size);

        // Convert to Braille (with optional timing for debug builds)
        const convert_start = if (builtin.mode == .Debug) nowNs(io) else 0;
        const braille_text = try conv.convert(frame, dims.cols, dims.rows, frame_allocator);
        const convert_end = if (builtin.mode == .Debug) nowNs(io) else 0;

        // Clear screen right before rendering
        try term.clearScreen(stdout);

        // Print the frame
        try stdout.writeAll(braille_text);

        // Capture time after rendering (before debug output)
        const render_end = if (builtin.mode == .Debug) nowNs(io) else 0;

        // Print debug timing info (only in debug builds)
        if (builtin.mode == .Debug) {
            const convert_ms = nsToMs(convert_end - convert_start);
            const render_ms = nsToMs(render_end - convert_end);
            const total_ms = nsToMs(render_end - start_time);
            const fps = 1000.0 / total_ms;
            try stdout.print("\nFPS: {d:.1} | Convert: {d:.1}ms | Render: {d:.1}ms | Total: {d:.1}ms\n", .{ fps, convert_ms, render_ms, total_ms });
        }

        try stdout.flush();

        // FPS capping: sleep for remaining time to achieve 60 FPS
        const frame_time = nowNs(io) - start_time;
        if (frame_time < target_frame_time_ns) {
            const remaining: Io.Duration = .fromNanoseconds(target_frame_time_ns - frame_time);
            io.sleep(remaining, .awake) catch {};
        }
    }
}

test "simple test" {
    const gpa = std.testing.allocator;
    var list: std.ArrayList(i32) = .empty;
    defer list.deinit(gpa); // Try commenting this out and see if zig detects the memory leak!
    try list.append(gpa, 42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}

test "fuzz example" {
    const Context = struct {
        fn testOne(context: @This(), input: []const u8) anyerror!void {
            _ = context;
            // Try passing `--fuzz` to `zig build test` and see if it manages to fail this test case!
            try std.testing.expect(!std.mem.eql(u8, "canyoufindme", input));
        }
    };
    try std.testing.fuzz(Context{}, Context.testOne, .{});
}
