const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Globals = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    layer_shell: ?*zwlr.LayerShellV1,
};

const State = struct {
    surface: *wl.Surface,
    configured: bool,
    running: bool,
    width: u32 = 0,
    height: u32 = 0,
};

const scaling = 2; //PLACEHOLDER

pub fn main() anyerror!void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    var globals = Globals{
        .shm = null,
        .compositor = null,
        .layer_shell = null,
    };

    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = globals.shm orelse return error.NoWlShm;
    defer shm.destroy();
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    defer compositor.destroy();
    const layer_shell = globals.layer_shell orelse return error.NoLayerShell;
    defer layer_shell.destroy();

    const surface = try compositor.createSurface();
    defer surface.destroy();

    // No xdg_surface/xdg_toplevel — layer shell gives the surface its role directly.
    // Passing null for output lets the compositor pick (usually the focused one).
    const layer_surface = try layer_shell.getLayerSurface(
        surface,
        null,
        .top, // layer: background/bottom/top/overlay
        "hello-zig-wayland",
    );
    defer layer_surface.destroy();

    layer_surface.setAnchor(.{ .top = true, .left = true, .right = true });
    layer_surface.setSize(0, 40);
    layer_surface.setExclusiveZone(10); // 0 = don't reserve space; set >0 for a real bar

    var state: State = .{
        .surface = surface,
        .configured = false,
        .running = true,
    };

    layer_surface.setListener(*State, layerSurfaceListener, &state);

    surface.commit();
    while (!state.configured) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }

    const buffer = blk: {
        std.debug.print("state size: {}, {}", .{ state.width, state.height });
        const width = state.width;
        const height = state.height;
        const stride = width * 4;
        const size = stride * height;

        const fd = try posix.memfd_create("hello-zig-wayland", 0);
        if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
        const data = try posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );

        for (0..(width * height)) |i| {
            data[i * 4] = 0x00; //B
            data[i * 4 + 1] = 0x00; //G
            data[i * 4 + 2] = 0xFF; //R
            data[i * 4 + 3] = 0xFF; //A
        }

        const pool = try shm.createPool(fd, @intCast(size));
        defer pool.destroy();

        break :blk try pool.createBuffer(0, @intCast(width), @intCast(height), @intCast(stride), wl.Shm.Format.argb8888);
    };
    defer buffer.destroy();

    surface.attach(buffer, 0, 0);
    surface.commit();

    while (state.running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
    switch (event) {
        .global => |global| {
            if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                globals.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                globals.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn layerSurfaceListener(layer_surface: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, state: *State) void {
    switch (event) {
        .configure => |configure| {
            state.width = configure.width;
            state.height = configure.height;
            layer_surface.ackConfigure(configure.serial);
            state.configured = true;
        },
        .closed => state.running = false,
    }
}
