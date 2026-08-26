const std = @import("std");
const Io = std.Io;
const dith = @import("dith");
const camera = dith.camera;
const depth = dith.depth;
const converter = dith.converter;
const term = dith.term;
const cli = dith.cli;
const image = dith.image;
const resample = dith.resample;
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

/// A frame copy that owns its planes, growing them as needed
const OwnedFrame = struct {
    const Plane = struct {
        data: []u8 = &.{},
        width: u32 = 0,
        height: u32 = 0,
        bytes_per_row: u32 = 0,
        present: bool = false,

        fn ensure(self: *Plane, allocator: std.mem.Allocator, len: usize) !void {
            if (self.data.len != len) {
                allocator.free(self.data);
                self.data = &.{};
                self.data = try allocator.alloc(u8, len);
            }
        }

        fn copy(self: *Plane, allocator: std.mem.Allocator, data: []const u8, width: u32, height: u32, bytes_per_row: u32) !void {
            try self.ensure(allocator, data.len);
            @memcpy(self.data, data);
            self.width = width;
            self.height = height;
            self.bytes_per_row = bytes_per_row;
            self.present = true;
        }

        fn deinit(self: *Plane, allocator: std.mem.Allocator) void {
            allocator.free(self.data);
            self.* = .{};
        }
    };

    luma: Plane = .{},
    chroma: Plane = .{},
    mask: Plane = .{},

    fn deinit(self: *OwnedFrame, allocator: std.mem.Allocator) void {
        self.luma.deinit(allocator);
        self.chroma.deinit(allocator);
        self.mask.deinit(allocator);
    }

    fn copyFrom(self: *OwnedFrame, allocator: std.mem.Allocator, frame: camera.Image) !void {
        try self.luma.copy(allocator, frame.data, frame.width, frame.height, frame.bytes_per_row);
        if (frame.chroma) |src| {
            try self.chroma.copy(allocator, src.data, src.width, src.height, src.bytes_per_row);
        } else self.chroma.present = false;
        if (frame.mask) |src| {
            try self.mask.copy(allocator, src.data, src.width, src.height, src.bytes_per_row);
        } else self.mask.present = false;
    }

    fn toImage(self: *const OwnedFrame) camera.Image {
        return .{
            .data = self.luma.data,
            .width = self.luma.width,
            .height = self.luma.height,
            .bytes_per_row = self.luma.bytes_per_row,
            .chroma = if (self.chroma.present) .{
                .data = self.chroma.data,
                .width = self.chroma.width,
                .height = self.chroma.height,
                .bytes_per_row = self.chroma.bytes_per_row,
            } else null,
            .mask = if (self.mask.present) .{
                .data = self.mask.data,
                .width = self.mask.width,
                .height = self.mask.height,
                .bytes_per_row = self.mask.bytes_per_row,
            } else null,
        };
    }
};

/// Double-buffered frame pipeline that captures frames on a background task
/// while the main thread processes previously captured frames.
const PipelinedCapture = struct {
    camera: *camera.Camera,
    allocator: std.mem.Allocator,
    io: Io,

    buffers: [2]OwnedFrame,
    write_idx: usize,
    /// The main thread's own copy of the latest frame, so the capture task
    /// can never write into memory being rendered
    front: OwnedFrame,

    mutex: Io.Mutex,
    capture_task: Io.Future(void),
    should_stop: std.atomic.Value(bool),

    const Self = @This();

    /// Initialize pipeline and start the background capture task
    pub fn init(allocator: std.mem.Allocator, io: Io, cam: *camera.Camera) !*Self {
        const pipeline = try allocator.create(Self);
        errdefer allocator.destroy(pipeline);

        pipeline.* = .{
            .camera = cam,
            .allocator = allocator,
            .io = io,
            .buffers = .{ .{}, .{} },
            .write_idx = 0,
            .front = .{},
            .mutex = .init,
            .should_stop = .init(false),
            .capture_task = undefined,
        };
        errdefer for (&pipeline.buffers) |*buf| buf.deinit(allocator);

        // Seed both buffers so the first read is a real frame
        const initial_frame = try cam.captureFrame();
        try pipeline.buffers[0].copyFrom(allocator, initial_frame);
        try pipeline.buffers[1].copyFrom(allocator, initial_frame);

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

        // Copy the buffer that's NOT being written to; on allocation failure
        // keep showing the previous frame
        const read_idx = 1 - self.write_idx;
        self.front.copyFrom(self.allocator, self.buffers[read_idx].toImage()) catch {};
        return self.front.toImage();
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.should_stop.store(true, .release);
        self.capture_task.await(self.io);

        for (&self.buffers) |*buf| buf.deinit(self.allocator);
        self.front.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Background task that continuously captures frames
    fn captureLoop(self: *Self) void {
        while (!self.should_stop.load(.acquire)) {
            // Capture frame (may fail, just continue to next iteration)
            const frame = self.camera.captureFrame() catch continue;

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            // Copy frame data into the buffer not currently being read
            self.buffers[self.write_idx].copyFrom(self.allocator, frame) catch continue;

            // Swap: this buffer is now ready, start writing to the other
            self.write_idx = 1 - self.write_idx;
        }
    }
};

/// Keeps the dots steady when the scene is still. Error diffusion is chaotic:
/// a one-level change in any pixel re-rolls every dot downstream of it, so
/// the input must be byte-identical between frames for the pattern to hold.
/// Each pixel keeps a running mean of its readings (which shrinks sensor
/// noise) and the value handed to the dither only moves when that mean has
/// drifted past the noise floor.
const Smoother = struct {
    allocator: std.mem.Allocator,
    /// Weight of the running mean over the new reading, 0-256
    keep: u32,
    frame: OwnedFrame = .{},
    /// Running means, 8.8 fixed point, one per plane: a fast one that
    /// catches real change with little lag, and a slow one that follows fine
    /// drift with almost no noise left in it
    luma_mean: []u16 = &.{},
    luma_slow: []u16 = &.{},
    chroma_mean: []u16 = &.{},
    chroma_slow: []u16 = &.{},
    mask_mean: []u16 = &.{},
    mask_slow: []u16 = &.{},
    /// Which luma pixels moved this frame; lets the dither leave the rest alone
    changed: []u8 = &.{},
    /// Debug builds: share of raw readings further than 6/12/24 levels from
    /// the shown value, to see the sensor noise directly
    noise_tail: [3]f64 = .{ 0, 0, 0 },
    /// Debug builds: mean(raw) - mean(shown) this frame, to see global breathing
    global_delta: f64 = 0,
    /// Frames since the luma plane was (re)started
    frames_since_restart: u32 = 0,
    /// Frame-wide brightness drift (auto-exposure) tracked apart from
    /// per-pixel change, in 1/256 levels. A level or two across the whole
    /// frame is invisible, so it is subtracted before the per-pixel compare
    /// instead of making every pixel cross its hold one by one.
    drift: i32 = 0,

    /// Once the drift amounts to this many levels it is folded into the
    /// picture in one go (a whole-frame refresh, like a scene cut)
    const drift_resync: i32 = 8;

    /// The slow mean may sit this far from the shown value before the pixel
    /// follows it. Kept small: whatever a pixel is allowed to hold becomes
    /// frozen noise the dither renders as blotches, so the slow mean has to
    /// do the noise work, not this.
    const noise_floor: u32 = 3;
    /// The fast mean this far from the shown value is real change, followed
    /// at once so motion does not ghost
    const change_floor: u32 = 14;
    /// Weight of the slow mean over a new reading, 0-256
    const slow_keep: u32 = 248;
    /// Frames after a (re)start during which the fast mean may settle pixels
    /// at the noise floor: the first frame is a single noisy sample and the
    /// slow mean takes too long to correct it
    const settling_frames: u32 = 30;

    fn init(allocator: std.mem.Allocator, weight: f32) Smoother {
        return .{ .allocator = allocator, .keep = @intFromFloat(@round(weight * 256.0)) };
    }

    fn deinit(self: *Smoother) void {
        self.frame.deinit(self.allocator);
        self.allocator.free(self.luma_mean);
        self.allocator.free(self.luma_slow);
        self.allocator.free(self.chroma_mean);
        self.allocator.free(self.chroma_slow);
        self.allocator.free(self.mask_mean);
        self.allocator.free(self.mask_slow);
        self.allocator.free(self.changed);
    }

    /// Returns the steadied frame (a view into the smoother's own buffers)
    fn apply(self: *Smoother, frame: camera.Image) !camera.Image {
        if (self.keep == 0) return frame;

        if (builtin.mode == .Debug and self.frame.luma.present and self.frame.luma.data.len == frame.data.len) {
            var over = [3]usize{ 0, 0, 0 };
            var signed: i64 = 0;
            for (self.frame.luma.data, frame.data) |shown, raw| {
                const d = if (raw > shown) raw - shown else shown - raw;
                if (d > 6) over[0] += 1;
                if (d > 12) over[1] += 1;
                if (d > 24) over[2] += 1;
                signed += @as(i64, raw) - shown;
            }
            const n: f64 = @floatFromInt(frame.data.len);
            for (0..3) |i| self.noise_tail[i] = 100.0 * @as(f64, @floatFromInt(over[i])) / n;
            self.global_delta = @as(f64, @floatFromInt(signed)) / n;
        }
        // Track frame-wide drift against what is shown
        var offset: i32 = 0;
        if (self.frame.luma.present and self.frame.luma.data.len == frame.data.len) {
            var signed: i64 = 0;
            for (self.frame.luma.data, frame.data) |shown, raw| signed += @as(i64, raw) - shown;
            const delta: i32 = @intCast(@divTrunc(signed * 256, @as(i64, @intCast(frame.data.len))));
            self.drift += @divTrunc((delta - self.drift) * 26, 256); // ease at ~0.1 per frame
            offset = @divTrunc(self.drift + 128, 256);
            if (offset >= drift_resync or offset <= -drift_resync) {
                // Fold the drift in: everything moves together, once
                for (self.frame.luma.data, self.luma_mean, self.luma_slow) |*shown, *mean, *slow| {
                    const v: i32 = @as(i32, shown.*) + offset;
                    shown.* = @intCast(@max(0, @min(255, v)));
                    mean.* = @intCast(@as(u32, shown.*) << 8);
                    slow.* = mean.*;
                }
                @memset(self.changed, 1);
                self.drift = 0;
                offset = 0;
                self.frame.luma.present = true;
                if (frame.chroma) |src| _ = try self.settlePlane(&self.frame.chroma, &self.chroma_mean, &self.chroma_slow, src.data, src.width, src.height, src.bytes_per_row, false, 0) else self.frame.chroma.present = false;
                if (frame.mask) |src| _ = try self.settlePlane(&self.frame.mask, &self.mask_mean, &self.mask_slow, src.data, src.width, src.height, src.bytes_per_row, false, 0) else self.frame.mask.present = false;
                var refreshed = self.frame.toImage();
                refreshed.changed = .{ .data = self.changed, .width = refreshed.width, .height = refreshed.height, .bytes_per_row = refreshed.bytes_per_row };
                return refreshed;
            }
        }

        const luma_reset = try self.settlePlane(&self.frame.luma, &self.luma_mean, &self.luma_slow, frame.data, frame.width, frame.height, frame.bytes_per_row, true, offset);
        self.frames_since_restart = if (luma_reset) 0 else self.frames_since_restart +| 1;
        if (frame.chroma) |src| {
            _ = try self.settlePlane(&self.frame.chroma, &self.chroma_mean, &self.chroma_slow, src.data, src.width, src.height, src.bytes_per_row, false, 0);
        } else self.frame.chroma.present = false;
        if (frame.mask) |src| {
            _ = try self.settlePlane(&self.frame.mask, &self.mask_mean, &self.mask_slow, src.data, src.width, src.height, src.bytes_per_row, false, 0);
        } else self.frame.mask.present = false;

        var out = self.frame.toImage();
        if (!luma_reset) {
            out.changed = .{ .data = self.changed, .width = out.width, .height = out.height, .bytes_per_row = out.bytes_per_row };
        }
        return out;
    }

    /// Feed one plane's new readings through mean + deadband into `shown`.
    /// Returns true when the plane was (re)started from scratch.
    fn settlePlane(self: *Smoother, shown: *OwnedFrame.Plane, mean: *[]u16, slow: *[]u16, data: []const u8, width: u32, height: u32, bytes_per_row: u32, track_changes: bool, offset: i32) !bool {
        const restart = !shown.present or shown.data.len != data.len or shown.width != width or shown.height != height;
        if (restart) {
            try shown.copy(self.allocator, data, width, height, bytes_per_row);
            if (mean.len != data.len) {
                self.allocator.free(mean.*);
                mean.* = &.{};
                mean.* = try self.allocator.alloc(u16, data.len);
                self.allocator.free(slow.*);
                slow.* = &.{};
                slow.* = try self.allocator.alloc(u16, data.len);
            }
            for (mean.*, slow.*, data) |*m, *sl, v| {
                m.* = @as(u16, v) << 8;
                sl.* = m.*;
            }
            if (track_changes) {
                if (self.changed.len != data.len) {
                    self.allocator.free(self.changed);
                    self.changed = &.{};
                    self.changed = try self.allocator.alloc(u8, data.len);
                }
                @memset(self.changed, 1);
            }
            return true;
        }
        settle(mean.*, slow.*, shown.data, data, self.keep, if (track_changes) self.changed else null, offset, self.frames_since_restart < settling_frames);
        return false;
    }

    /// Two running means per pixel. The shown value follows the fast mean
    /// at once when it has clearly moved (real change), and otherwise
    /// follows the slow mean only once it has drifted past the noise floor.
    fn settle(fast: []u16, slow: []u16, shown: []u8, readings: []const u8, keep: u32, changed: ?[]u8, offset: i32, settling: bool) void {
        const take = 256 - keep;
        const take_slow = 256 - slow_keep;
        for (fast, slow, shown, readings, 0..) |*fm, *sm, *s, reading, i| {
            // Readings are taken relative to the tracked frame-wide drift
            const adjusted: u32 = @intCast(@max(0, @min(255, @as(i32, reading) - offset)));
            const target: u32 = adjusted << 8;

            fm.* = @intCast(ease(fm.*, target, take));
            sm.* = @intCast(ease(sm.*, target, take_slow));

            const visible: u32 = s.*;
            const fast_level: u32 = (@as(u32, fm.*) + 128) >> 8;
            const slow_level: u32 = (@as(u32, sm.*) + 128) >> 8;
            const fast_drift = if (fast_level > visible) fast_level - visible else visible - fast_level;
            const slow_drift = if (slow_level > visible) slow_level - visible else visible - slow_level;

            var moved = false;
            if (fast_drift > change_floor or (settling and fast_drift > noise_floor)) {
                s.* = @intCast(@min(255, fast_level));
                sm.* = fm.*;
                moved = true;
            } else if (slow_drift > noise_floor) {
                s.* = @intCast(@min(255, slow_level));
                moved = true;
            }
            if (changed) |c| c[i] = if (moved) 1 else 0;
        }
    }

    inline fn ease(current: u32, target: u32, take: u32) u32 {
        return if (target >= current)
            current + (((target - current) * take) >> 8)
        else
            current - (((current - target) * take) >> 8);
    }
};

/// Print a message to stderr and exit with failure
fn failWith(io: Io, comptime fmt: []const u8, args: anytype) !noreturn {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writerStreaming(io, &buffer);
    const stderr = &writer.interface;
    stderr.print(fmt, args) catch {};
    stderr.flush() catch {};
    std.process.exit(1);
}

/// Find (downloading if needed) and load the depth model
fn loadDepthModel(io: Io, allocator: std.mem.Allocator, home: ?[]const u8, explicit: ?[]const u8) !depth.Model {
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stderr().writerStreaming(io, &buffer);
    const stderr = &writer.interface;

    const paths = depth.resolvePaths(allocator, io, home, explicit, stderr) catch |err| switch (err) {
        error.NoHomeDirectory => try failWith(io, "error: no home directory to cache the depth model in; pass +model=<path>\n", .{}),
        error.DownloadFailed => try failWith(io, "error: the depth model could not be downloaded; check your connection or pass +model=<path>\n", .{}),
        error.OutOfMemory => return err,
    };
    defer paths.deinit(allocator);

    stderr.writeAll("Loading the depth model...\n") catch {};
    stderr.flush() catch {};
    return depth.Model.init(paths.model, paths.compiled) catch |err| {
        try failWith(io, "error: could not load the depth model at {s} ({t})\n", .{ paths.model, err });
    };
}

/// Set by SIGINT/SIGTERM so the frame loop exits normally and every defer
/// (camera session, capture task, terminal state) gets to run
var quit_requested = std.atomic.Value(bool).init(false);

fn requestQuit(_: std.posix.SIG) callconv(.c) void {
    quit_requested.store(true, .release);
}

fn installQuitHandlers() void {
    const act: std.posix.Sigaction = .{
        .handler = .{ .handler = requestQuit },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
    std.posix.sigaction(.TERM, &act, null);
}

/// Frame capture strategy selection
const CaptureStrategy = enum {
    direct, // Simple blocking capture (no pipelining)
    pipelined, // Double-buffered background task
};

/// Initialize converter based on CLI mode selection
fn initConverter(mode: cli.Mode, shading: converter.Shading, allocator: std.mem.Allocator) !converter.Converter {
    return switch (mode) {
        .edge => |cfg| blk: {
            const conv = try converter.EdgeConverter.init(allocator, cfg.threshold, cfg.invert);
            conv.shading = shading;
            break :blk conv.converter();
        },
        .atkinson => |cfg| blk: {
            const conv = try converter.AtkinsonConverter.init(allocator, cfg.threshold, cfg.invert);
            conv.shading = shading;
            break :blk conv.converter();
        },
        .floyd_steinberg => |cfg| blk: {
            const conv = try converter.FloydSteinbergConverter.init(allocator, cfg.threshold, cfg.invert);
            conv.shading = shading;
            break :blk conv.converter();
        },
        .blue_noise => |cfg| blk: {
            const conv = try converter.BlueNoiseConverter.init(allocator, cfg.threshold, cfg.invert);
            conv.shading = shading;
            break :blk conv.converter();
        },
        .bayer => |cfg| blk: {
            const conv = try converter.BayerConverter.init(allocator, cfg.threshold, cfg.invert);
            conv.shading = shading;
            break :blk conv.converter();
        },
    };
}

fn isThemeCommand(process_args: std.process.Args) bool {
    var it = process_args.iterate();
    _ = it.next();
    const first = it.next() orelse return false;
    return std.mem.eql(u8, first, "+theme");
}

fn printTheme(io: Io) !void {
    const theme = term.queryTheme(theme_probe_timeout_ms);
    var buffer: [1024]u8 = undefined;
    var writer = Io.File.stdout().writerStreaming(io, &buffer);
    const stdout = &writer.interface;
    try stdout.print("foreground  #{x:0>2}{x:0>2}{x:0>2}\n", .{ theme.fg[0], theme.fg[1], theme.fg[2] });
    try stdout.print("background  #{x:0>2}{x:0>2}{x:0>2}\n", .{ theme.bg[0], theme.bg[1], theme.bg[2] });
    for (theme.colors, 0..) |c, i| {
        try stdout.print("color {d:>2}    #{x:0>2}{x:0>2}{x:0>2}\n", .{ i, c[0], c[1], c[2] });
    }
    try stdout.flush();
}

/// How long to wait for the terminal to answer color queries
const theme_probe_timeout_ms = 150;

/// Shading from the CLI options. Only asks the terminal for its colors when
/// a channel is actually on, since that costs a round-trip.
fn buildShading(shade: cli.Shade) converter.Shading {
    if (shade.gamma == null and !shade.color and !shade.depth) return .none;

    var theme = term.queryTheme(theme_probe_timeout_ms);
    if (shade.fg) |c| theme.fg = c;
    if (shade.bg) |c| theme.bg = c;

    return converter.Shading.init(.{
        .gamma = shade.gamma,
        .color = shade.color,
        .depth = shade.depth,
        .theme = theme,
    });
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

    // `+theme`: report what the terminal says about its colors, then exit
    if (isThemeCommand(init.minimal.args)) return printTheme(io);

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

    // Optional brightness/color/depth channels; `.none` keeps the plain fast path
    const shading = buildShading(args.shade);

    // Depth needs the model; anything else never touches it
    var depth_model: ?depth.Model = null;
    defer if (depth_model) |*m| m.deinit();
    if (args.shade.depth) {
        depth_model = try loadDepthModel(io, allocator, init.environ_map.get("HOME"), args.shade.model);
    }

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
            const conv = try initConverter(args.mode, shading, allocator);
            defer conv.deinit();

            var source_frame = img.toImage();
            if (depth_model) |*m| {
                source_frame.mask = m.estimateRgb(img.rgb, img.width, img.height, img.width * 3) catch |err| {
                    try failWith(io, "error: the depth model could not process this image ({t})\n", .{err});
                };
            }

            // Dither at the dot grid's own resolution so every dot counts
            const dims = term.calculateBrailleDimensions(source_frame, term_size);
            var grid = resample.Frame.init(allocator);
            defer grid.deinit();
            const frame = try grid.downsample(source_frame, dims.cols * 2, dims.rows * 4);
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

    // Leave the camera and terminal in a clean state on Ctrl-C
    installQuitHandlers();

    // Open camera
    try cam.open();
    defer cam.close();

    // Frames carry a nearness mask while a depth model is attached
    if (depth_model) |*m| cam.setDepthModel(m);
    defer cam.setDepthModel(null);

    // Initialize converter based on mode
    const conv = try initConverter(args.mode, shading, allocator);
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

    var grid = resample.Frame.init(allocator);
    defer grid.deinit();
    var smoother = Smoother.init(allocator, cam_config.smooth);
    defer smoother.deinit();

    // Target 60 FPS: 1/60 second = 16.666ms = 16,666,666 nanoseconds
    const target_frame_time_ns: i96 = 16_666_666;

    // Clear once; every frame after that overwrites the same cells in place
    try term.clearScreen(stdout);
    defer {
        // Leave the terminal with default colors and the cursor below the picture
        stdout.print("\x1b[0m\x1b[{d};1H\n", .{term_size.rows}) catch {};
        stdout.flush() catch {};
    }

    // Continuous frame loop
    while (!quit_requested.load(.acquire)) {
        // Start timing
        const start_time = nowNs(io);

        _ = frame_arena.reset(.retain_capacity);
        const frame_allocator = frame_arena.allocator();

        // Next frame (captured on the background task), brought down to the
        // dot grid's resolution so every dot counts, then steadied
        const captured = source.getNextFrame();
        const dims = term.calculateBrailleDimensions(captured, term_size);
        const grid_frame = try grid.downsample(captured, dims.cols * 2, dims.rows * 4);
        if (builtin.mode == .Debug) {
            // DITH_DUMP=<path>: append raw grid luma frames for offline analysis
            if (init.environ_map.get("DITH_DUMP")) |path| {
                const file = try Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
                defer file.close(io);
                var header: [8]u8 = undefined;
                std.mem.writeInt(u32, header[0..4], grid_frame.width, .little);
                std.mem.writeInt(u32, header[4..8], grid_frame.height, .little);
                var fw_buf: [4096]u8 = undefined;
                var fw = file.writer(io, &fw_buf);
                try fw.seekTo(try file.length(io));
                try fw.interface.writeAll(&header);
                try fw.interface.writeAll(grid_frame.data);
                try fw.interface.flush();
            }
        }
        const frame = try smoother.apply(grid_frame);

        // Convert to Braille (with optional timing for debug builds)
        const convert_start = if (builtin.mode == .Debug) nowNs(io) else 0;
        const braille_text = try conv.convert(frame, dims.cols, dims.rows, frame_allocator);
        const convert_end = if (builtin.mode == .Debug) nowNs(io) else 0;

        // Present the frame in place, held until complete. Rows are placed
        // explicitly so a full-height picture never scrolls the screen.
        try term.beginFrame(stdout);
        try term.writeLinesInPlace(stdout, braille_text, 1);

        // Capture time after rendering (before debug output)
        const render_end = if (builtin.mode == .Debug) nowNs(io) else 0;

        // Print debug timing info (only in debug builds, and only when there
        // is a spare row below the picture)
        if (builtin.mode == .Debug and dims.rows < term_size.rows) {
            const convert_ms = nsToMs(convert_end - convert_start);
            const render_ms = nsToMs(render_end - convert_end);
            const total_ms = nsToMs(render_end - start_time);
            const fps = 1000.0 / total_ms;
            try stdout.print("\x1b[{d};1HFPS: {d:.1} | Convert: {d:.1}ms | Render: {d:.1}ms | Total: {d:.1}ms", .{ dims.rows + 1, fps, convert_ms, render_ms, total_ms });
            if (frame.changed) |ch| {
                // How much of the frame moved, and how much the dither revisits
                var moved: usize = 0;
                for (ch.data) |v| moved += @intFromBool(v != 0);
                const redo = try converter.common.dilateChanged(ch, frame.width, frame.height, frame_allocator);
                var revisited: usize = 0;
                for (redo) |v| revisited += v;
                const total: f64 = @floatFromInt(frame.width * frame.height);
                try stdout.print(" | Moved: {d:.2}% | Redo: {d:.1}% | Raw >6/12/24: {d:.1}/{d:.1}/{d:.1}% | Global: {d:.2} | Drift: {d}", .{ 100.0 * @as(f64, @floatFromInt(moved)) / total, 100.0 * @as(f64, @floatFromInt(revisited)) / total, smoother.noise_tail[0], smoother.noise_tail[1], smoother.noise_tail[2], smoother.global_delta, @divTrunc(smoother.drift + 128, 256) });
            }
            try term.clearToLineEnd(stdout);
        }

        try term.endFrame(stdout);
        try stdout.flush();

        // FPS capping: sleep for remaining time to achieve 60 FPS
        const frame_time = nowNs(io) - start_time;
        if (frame_time < target_frame_time_ns) {
            const remaining: Io.Duration = .fromNanoseconds(target_frame_time_ns - frame_time);
            io.sleep(remaining, .awake) catch {};
        }
    }
}

test "Smoother.settle ignores noise and follows real change" {
    var fast = [_]u16{ 100 << 8, 100 << 8, 100 << 8 };
    var slow = [_]u16{ 100 << 8, 100 << 8, 100 << 8 };
    var shown = [_]u8{ 100, 100, 100 };
    var changed = [_]u8{ 9, 9, 9 };

    // Noisy readings around 100 never move the shown value
    const noisy = [_][3]u8{ .{ 104, 96, 100 }, .{ 97, 105, 100 }, .{ 103, 95, 100 } };
    for (noisy) |r| {
        Smoother.settle(&fast, &slow, &shown, &r, 128, &changed, 0, false);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 100, 100, 100 }, &shown);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0 }, &changed);
    }

    // A real step is followed within a few frames and flagged as a change
    var frames: usize = 0;
    while (shown[2] < 170 and frames < 20) : (frames += 1) {
        Smoother.settle(&fast, &slow, &shown, &[_]u8{ 100, 100, 180 }, 128, &changed, 0, false);
    }
    try std.testing.expect(frames < 6);
    try std.testing.expectEqual(@as(u8, 1), changed[2]);
    try std.testing.expectEqual(@as(u8, 0), changed[0]);
}

test "Smoother holds a still noisy scene: almost no pixels move per frame" {
    const allocator = std.testing.allocator;
    const w: u32 = 160;
    const h: u32 = 90;
    var base: [w * h]u8 = undefined;
    for (0..h) |y| for (0..w) |x| {
        base[y * w + x] = @intCast(40 + (x * 120) / w + (y * 60) / h);
    };
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    var smoother = Smoother.init(allocator, 0.85);
    defer smoother.deinit();

    var frame: [w * h]u8 = undefined;
    var moved_total: usize = 0;
    var counted_frames: usize = 0;
    var f: usize = 0;
    while (f < 120) : (f += 1) {
        // Static scene + Gaussian-ish noise (sigma ~4) + slow brightening
        const drift: i32 = @intCast(f / 20);
        for (&frame, base) |*dst, b| {
            var n: i32 = 0;
            for (0..12) |_| n += @as(i32, random.intRangeAtMost(i8, -6, 6));
            n = @divTrunc(n, 3);
            dst.* = @intCast(@max(0, @min(255, @as(i32, b) + n + drift)));
        }
        const out = try smoother.apply(.{ .data = &frame, .width = w, .height = h, .bytes_per_row = w });
        var moved: usize = w * h; // a restart counts as everything moving
        if (out.changed) |ch| {
            moved = 0;
            for (ch.data) |v| moved += @intFromBool(v != 0);
        }
        if (f >= 40) {
            moved_total += moved;
            counted_frames += 1;
        }
        if (f == 10 or f == 30 or f == 60 or f == 119) std.debug.print("\nframe {d}: moved {d:.3}%", .{ f, 100.0 * @as(f64, @floatFromInt(moved)) / @as(f64, @floatFromInt(w * h)) });
    }
    const per_frame = @as(f64, @floatFromInt(moved_total)) / @as(f64, @floatFromInt(counted_frames)) / @as(f64, @floatFromInt(w * h));
    std.debug.print("\nstill-scene moved per frame (after settling): {d:.3}%\n", .{per_frame * 100});
    try std.testing.expect(per_frame < 0.001);
}
