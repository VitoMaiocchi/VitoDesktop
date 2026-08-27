const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const scanner = Scanner.create(b, .{});

    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");

    scanner.generate("wl_seat", 4);
    scanner.generate("xdg_wm_base", 3);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_shm", 1);

    scanner.addCustomProtocol(b.path("protocols/wlr-layer-shell-unstable-v1.xml"));
    scanner.generate("zwlr_layer_shell_v1", 4); // or whatever version you're targeting

    const exe = b.addExecutable(.{
        .name = "my_program",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    exe.root_module.addImport("wayland", wayland);
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("cairo", .{});

    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| {
        run.addArgs(args);
    }

    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run.step);
}
