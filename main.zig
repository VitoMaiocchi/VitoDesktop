const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const cairo = @cImport({
    @cInclude("cairo/cairo.h");
});

const OutputInfo = struct {
    output: *wl.Output,
    name: u32, // the wl_registry global name, useful as a stable key
    width: i32 = 0,
    height: i32 = 0,
    scale: i32 = 1,
    done: bool = false, // set once compositor signals this output's info is complete
};

const Globals = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    layer_shell: ?*zwlr.LayerShellV1,
    outputs: std.ArrayList(OutputInfo),
    allocator: std.mem.Allocator,
};

const State = struct {
    surface: *wl.Surface,
    configured: bool,
    running: bool,
    width: u32 = 0,
    height: u32 = 0,
};

pub fn main() anyerror!void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) std.debug.print("memory leak detected\n", .{});
    }
    const allocator = gpa.allocator();

    var globals = Globals{
        .shm = null,
        .compositor = null,
        .layer_shell = null,
        .outputs = std.ArrayList(OutputInfo).empty,
        .allocator = allocator,
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
    layer_surface.setSize(0, 30);
    layer_surface.setExclusiveZone(30); // 0 = don't reserve space; set >0 for a real bar

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

        drawTitlebar(data.ptr, cairo.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height), @intCast(stride));

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
                globals.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                globals.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                globals.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 1) catch return;
            } else if (mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                const output = registry.bind(global.name, wl.Output, 4) catch return; // v2+ for scale event
                globals.outputs.append(globals.allocator, .{ .output = output, .name = global.name }) catch return;
                const info = &globals.outputs.items[globals.outputs.items.len - 1];
                output.setListener(*OutputInfo, outputListener, info);
                std.debug.print("output {} has been created\n", .{info.name});
            }
        },
        .global_remove => |remove| {
            for (globals.outputs.items, 0..) |o, i| {
                if (o.name == remove.name) {
                    o.output.release(); // or .destroy() depending on your zig-wayland version's naming
                    const output = globals.outputs.swapRemove(i);
                    std.debug.print("output {} is released\n", .{output.name});
                    break;
                }
            }
        },
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

fn outputListener(_: *wl.Output, event: wl.Output.Event, info: *OutputInfo) void {
    switch (event) {
        .mode => |mode| {
            if (mode.flags.current) {
                info.width = mode.width;
                info.height = mode.height;
            }
        },
        .scale => |scale_event| {
            info.scale = scale_event.factor;
        },
        .geometry => {},
        .done => {
            info.done = true;
            std.debug.print("Output {} info updated:\n  size={}x{}\n  scale={}\n", .{ info.name, info.height, info.width, info.scale });
        },
        else => {},
    }
}

fn drawTitlebar(data: [*c]u8, format: cairo.cairo_format_t, width: c_int, height: c_int, stride: c_int) void {
    // Wrap the mmap'd memory as a Cairo surface — no copy, same bytes.
    const cairo_surface = cairo.cairo_image_surface_create_for_data(
        data,
        format,
        width,
        height,
        stride,
    );
    defer cairo.cairo_surface_destroy(cairo_surface);

    const cr = cairo.cairo_create(cairo_surface);
    defer cairo.cairo_destroy(cr);

    // --- draw here ---
    cairo.cairo_set_source_rgba(cr, 0.11, 0.12, 0.15, 1.0); // background
    cairo.cairo_paint(cr);

    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0); // text color
    cairo.cairo_select_font_face(cr, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(cr, 14.0);
    cairo.cairo_move_to(cr, 10, 25);
    cairo.cairo_show_text(cr, "Placeholder Text");
    // --- end draw ---

    cairo.cairo_surface_flush(cairo_surface); // ensure Cairo's writes are done before Wayland reads the buffer
}
