const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    const optimize = b.standardOptimizeOption(.{});

    // Base module: types (shared by all)
    const types_mod = b.addModule("types", .{
        .root_source_file = b.path("src/types.zig"),
        .target = target,
    });

    // Depth model (CoreML monocular depth). Zig 0.16 deprecates @cImport in
    // favor of translate-c driven from the build graph.
    const depth_c = b.addTranslateC(.{
        .root_source_file = b.path("deps/depth_model.h"),
        .target = target,
        .optimize = optimize,
    });
    const depth_mod = b.addModule("depth", .{
        .root_source_file = b.path("src/depth.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "c", .module = depth_c.createModule() },
        },
    });
    depth_mod.addIncludePath(b.path("deps"));
    depth_mod.addCSourceFile(.{
        .file = b.path("deps/depth_model.mm"),
        .flags = &[_][]const u8{ "-ObjC++", "-fno-objc-arc" },
    });
    depth_mod.link_libcpp = true;
    depth_mod.linkFramework("CoreML", .{});
    depth_mod.linkFramework("Vision", .{});
    depth_mod.linkFramework("CoreVideo", .{});
    depth_mod.linkFramework("Foundation", .{});

    // C bindings for the camera wrapper
    const camera_c = b.addTranslateC(.{
        .root_source_file = b.path("deps/camera_wrapper.h"),
        .target = target,
        .optimize = optimize,
    });

    // Camera module (depends on types, depth model, C bindings)
    const camera_mod = b.addModule("camera", .{
        .root_source_file = b.path("src/camera.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "depth", .module = depth_mod },
            .{ .name = "c", .module = camera_c.createModule() },
        },
    });
    camera_mod.addIncludePath(b.path("deps"));
    camera_mod.addCSourceFile(.{
        .file = b.path("deps/camera_wrapper.mm"),
        .flags = &[_][]const u8{ "-ObjC++", "-fno-objc-arc" },
    });

    camera_mod.link_libcpp = true;

    camera_mod.linkFramework("AVFoundation", .{});
    camera_mod.linkFramework("CoreMedia", .{});
    camera_mod.linkFramework("CoreVideo", .{});
    camera_mod.linkFramework("Foundation", .{});

    // Converter submodules
    const common_mod = b.addModule("converters/common", .{
        .root_source_file = b.path("src/converters/common.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    const edge_mod = b.addModule("converters/edge", .{
        .root_source_file = b.path("src/converters/edge.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const atkinson_mod = b.addModule("converters/atkinson", .{
        .root_source_file = b.path("src/converters/atkinson.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const floyd_steinberg_mod = b.addModule("converters/floyd_steinberg", .{
        .root_source_file = b.path("src/converters/floyd_steinberg.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "atkinson", .module = atkinson_mod },
        },
    });

    const blue_noise_mod = b.addModule("converters/blue_noise", .{
        .root_source_file = b.path("src/converters/blue_noise.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
        },
    });

    const bayer_mod = b.addModule("converters/bayer", .{
        .root_source_file = b.path("src/converters/bayer.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "common", .module = common_mod },
            .{ .name = "blue_noise", .module = blue_noise_mod },
        },
    });

    // Converter module (aggregates all converter submodules)
    const converter_mod = b.addModule("converter", .{
        .root_source_file = b.path("src/converter.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "converters/common", .module = common_mod },
            .{ .name = "converters/edge", .module = edge_mod },
            .{ .name = "converters/atkinson", .module = atkinson_mod },
            .{ .name = "converters/floyd_steinberg", .module = floyd_steinberg_mod },
            .{ .name = "converters/blue_noise", .module = blue_noise_mod },
            .{ .name = "converters/bayer", .module = bayer_mod },
        },
    });

    // Terminal module (depends on types; calls libc ioctl for the window size)
    const term_mod = b.addModule("term", .{
        .root_source_file = b.path("src/term.zig"),
        .target = target,
        .link_libc = true,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    // CLI module (depends on types)
    const cli_mod = b.addModule("cli", .{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
        },
    });

    // C bindings for stb_image (declarations only; the implementation is
    // compiled separately from stb_image_impl.c)
    const stb_image_c = b.addTranslateC(.{
        .root_source_file = b.path("deps/stb_image.h"),
        .target = target,
        .optimize = optimize,
    });

    // Image module (depends on types, uses stb_image)
    const image_mod = b.addModule("image", .{
        .root_source_file = b.path("src/image.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "c", .module = stb_image_c.createModule() },
        },
    });
    image_mod.addIncludePath(b.path("deps"));
    image_mod.addCSourceFile(.{
        .file = b.path("deps/stb_image_impl.c"),
    });
    image_mod.link_libc = true;

    // Main library module: dith (aggregates all submodules)
    const mod = b.addModule("dith", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "types", .module = types_mod },
            .{ .name = "camera", .module = camera_mod },
            .{ .name = "depth", .module = depth_mod },
            .{ .name = "converter", .module = converter_mod },
            .{ .name = "term", .module = term_mod },
            .{ .name = "cli", .module = cli_mod },
            .{ .name = "image", .module = image_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "dith",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),

            .target = target,
            .optimize = optimize,

            .imports = &.{
                .{ .name = "dith", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Camera module tests
    const camera_tests = b.addTest(.{
        .root_module = camera_mod,
    });
    const run_camera_tests = b.addRunArtifact(camera_tests);

    // Converter module tests. `zig test` only collects tests from the root
    // module, so each converter submodule gets its own test step.
    const converter_tests = b.addTest(.{
        .root_module = converter_mod,
    });
    const run_converter_tests = b.addRunArtifact(converter_tests);
    const converter_submodules = [_]*std.Build.Module{ common_mod, edge_mod, atkinson_mod, floyd_steinberg_mod, blue_noise_mod, bayer_mod };
    var run_converter_submodule_tests: [converter_submodules.len]*std.Build.Step.Run = undefined;
    for (converter_submodules, 0..) |submod, i| {
        run_converter_submodule_tests[i] = b.addRunArtifact(b.addTest(.{ .root_module = submod }));
    }

    // Image module tests
    const image_tests = b.addTest(.{
        .root_module = image_mod,
    });
    const run_image_tests = b.addRunArtifact(image_tests);

    // Depth module tests
    const depth_tests = b.addTest(.{
        .root_module = depth_mod,
    });
    const run_depth_tests = b.addRunArtifact(depth_tests);

    // Terminal module tests
    const term_tests = b.addTest(.{
        .root_module = term_mod,
    });
    const run_term_tests = b.addRunArtifact(term_tests);

    // Main dith module tests
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // CLI module tests
    const cli_tests = b.addTest(.{
        .root_module = cli_mod,
    });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    // Executable (main.zig) tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_camera_tests.step);
    test_step.dependOn(&run_converter_tests.step);
    for (run_converter_submodule_tests) |run| test_step.dependOn(&run.step);
    test_step.dependOn(&run_image_tests.step);
    test_step.dependOn(&run_depth_tests.step);
    test_step.dependOn(&run_term_tests.step);
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_cli_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
