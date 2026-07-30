const std = @import("std");
const mem = std.mem;
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const cairo = @cImport({
    @cInclude("cairo/cairo.h");
});

const Output = struct {
    output: *wl.Output,
    name: u32, // the wl_registry global name, useful as a stable key
    width: i32 = 0,
    height: i32 = 0,
    scale: i32 = 1,
    done: bool = false, // set once compositor signals this output's info is complete
    titlebar: *TitlebarSurface,
};

const Globals = struct {
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    layer_shell: ?*zwlr.LayerShellV1,
    outputs: std.ArrayList(Output),
    allocator: std.mem.Allocator,
};

const DrawableSurface = struct {
    data: [*c]u8,
    format: cairo.cairo_format_t,
    width: c_int,
    height: c_int,
    stride: c_int,
    scale: u32,
};

pub fn main() anyerror!void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    var globals = Globals{
        .shm = null,
        .compositor = null,
        .layer_shell = null,
        .outputs = std.ArrayList(Output).empty,
        .allocator = std.heap.page_allocator,
    };

    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = globals.shm orelse return error.NoWlShm;
    defer shm.destroy();
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    defer compositor.destroy();
    const layer_shell = globals.layer_shell orelse return error.NoLayerShell;
    defer layer_shell.destroy();

    while (true) {
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
                const wlOutput = registry.bind(global.name, wl.Output, 4) catch {
                    std.debug.print("ERROR: failed to bind output", .{});
                    return;
                };
                const titlebar = globals.allocator.create(TitlebarSurface) catch {
                    std.debug.print("ERROR: failed to create TitlebarSurface", .{});
                    return;
                };
                titlebar.globals = globals;
                globals.outputs.append(globals.allocator, .{ .output = wlOutput, .name = global.name, .titlebar = titlebar }) catch {
                    std.debug.print("ERROR: failed to add output to list", .{});
                    return;
                };
                const output = &globals.outputs.items[globals.outputs.items.len - 1];
                output.titlebar.create(output.output);
                wlOutput.setListener(*Output, outputListener, output);
                std.debug.print("output {} has been created\n", .{output.name});
            }
        },
        .global_remove => |remove| {
            for (globals.outputs.items, 0..) |o, i| {
                if (o.name == remove.name) {
                    o.output.release();
                    const output = globals.outputs.swapRemove(i);
                    output.titlebar.destroy();
                    std.debug.print("output {} is released\n", .{output.name});
                    break;
                }
            }
        },
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, info: *Output) void {
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
            info.titlebar.commit(info.scale);
        },
        else => {},
    }
}

const TitlebarSurface = struct {
    globals: *Globals,
    surface: ?*wl.Surface = null,
    layer_surface: ?*zwlr.LayerSurfaceV1 = null,
    width: u32 = 0,
    height: u32 = 0,
    scale: u32 = 1,

    pub fn create(self: *TitlebarSurface, output: *wl.Output) void {
        const compositor = self.globals.compositor orelse return;
        const layer_shell = self.globals.layer_shell orelse return;
        self.surface = compositor.createSurface() catch {
            std.debug.print("ERROR: failed to create titlebar surface", .{});
            return;
        };

        self.layer_surface = layer_shell.getLayerSurface(
            self.surface.?,
            output,
            .top, // layer: background/bottom/top/overlay
            "hello-zig-wayland",
        ) catch {
            std.debug.print("ERROR: failed to get titlebar layer surface", .{});
            return;
        };

        self.layer_surface.?.setAnchor(.{ .top = true, .left = true, .right = true });
        self.layer_surface.?.setSize(0, 30);
        self.layer_surface.?.setExclusiveZone(30); // 0 = don't reserve space; set >0 for a real bar

        self.layer_surface.?.setListener(*TitlebarSurface, layerSurfaceListener, self);
    }

    pub fn commit(self: *TitlebarSurface, scale: i32) void {
        self.scale = @intCast(scale);
        self.surface.?.setBufferScale(scale);
        self.surface.?.commit();
    }

    pub fn destroy(self: *TitlebarSurface) void {
        self.layer_surface.?.destroy();
        self.surface.?.destroy();
    }

    fn layerSurfaceListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *TitlebarSurface) void {
        switch (event) {
            .configure => |configure| {
                const shm = self.globals.shm orelse return;

                self.width = configure.width * self.scale;
                self.height = configure.height * self.scale;
                self.layer_surface.?.ackConfigure(configure.serial);

                const buffer = blk: {
                    const stride = self.width * 4;
                    const size = stride * self.height;

                    const fd = posix.memfd_create("hello-zig-wayland", 0) catch {
                        std.debug.print("ERROR: titlebar memfd create failed", .{});
                        return;
                    };
                    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) {
                        std.debug.print("layer surface listener truncate failed", .{});
                    }
                    const data = posix.mmap(
                        null,
                        @intCast(size),
                        .{ .READ = true, .WRITE = true },
                        .{ .TYPE = .SHARED },
                        fd,
                        0,
                    ) catch {
                        std.debug.print("ERROR: titlebar memory map failed", .{});
                        return;
                    };

                    const s = DrawableSurface{
                        .data = data.ptr,
                        .format = cairo.CAIRO_FORMAT_ARGB32,
                        .width = @intCast(self.width),
                        .height = @intCast(self.height),
                        .stride = @intCast(stride),
                        .scale = self.scale,
                    };
                    drawTitlebar(s);

                    const pool = shm.createPool(fd, @intCast(size)) catch {
                        std.debug.print("ERROR: titlebar create shm pool failed", .{});
                        return;
                    };
                    defer pool.destroy();

                    break :blk pool.createBuffer(0, @intCast(self.width), @intCast(self.height), @intCast(stride), wl.Shm.Format.argb8888) catch {
                        std.debug.print("ERROR: titlebar create buffer failed", .{});
                        return;
                    };
                };
                defer buffer.destroy();

                self.surface.?.attach(buffer, 0, 0);
                self.surface.?.commit();
            },
            .closed => {},
        }
    }
};

fn drawTitlebar(surface: DrawableSurface) void {
    const s: f64 = @floatFromInt(surface.scale);
    // Wrap the mmap'd memory as a Cairo surface — no copy, same bytes.
    const cairo_surface = cairo.cairo_image_surface_create_for_data(
        surface.data,
        surface.format,
        surface.width,
        surface.height,
        surface.stride,
    );
    defer cairo.cairo_surface_destroy(cairo_surface);

    const cr = cairo.cairo_create(cairo_surface);
    defer cairo.cairo_destroy(cr);

    // --- draw here ---
    cairo.cairo_set_source_rgba(cr, 0.11, 0.12, 0.15, 1.0); // background
    cairo.cairo_paint(cr);

    cairo.cairo_set_source_rgba(cr, 1.0, 1.0, 1.0, 1.0); // text color
    cairo.cairo_select_font_face(cr, "sans-serif", cairo.CAIRO_FONT_SLANT_NORMAL, cairo.CAIRO_FONT_WEIGHT_NORMAL);
    cairo.cairo_set_font_size(cr, s * 14.0);
    cairo.cairo_move_to(cr, 10 * s, 25 * s);
    cairo.cairo_show_text(cr, "Placeholder Text");
    // --- end draw ---

    cairo.cairo_surface_flush(cairo_surface); // ensure Cairo's writes are done before Wayland reads the buffer
}
