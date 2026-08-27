const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const cairo = @cImport({
    @cInclude("cairo/cairo.h");
});

const time = @cImport({
    @cInclude("time.h");
});

const Globals = struct {
    allocator: std.mem.Allocator,
    titlebarState: *TitlebarState,
    wayland: *Wayland,
};

const DrawableSurface = struct {
    data: [*c]u8,
    format: cairo.cairo_format_t,
    width: c_int,
    height: c_int,
    stride: c_int,
    scale: u32,
};

const TitlebarState = struct {
    currentTime: time.struct_tm,
};

const EventSource = struct {
    fd: std.posix.fd_t,
    events: i16,

    dispatchFn: *const fn (event: *const EventSource) anyerror!void,
    context: ?*anyopaque,

    pub fn dispatch(self: *const EventSource) anyerror!void {
        return self.dispatchFn(self);
    }
};

fn dispatchTimerEvent(event: *const EventSource) anyerror!void {
    const globals: *Globals = @ptrCast(@alignCast(event.context.?));
    var expirations: u64 = undefined;
    _ = linux.read(
        event.fd,
        std.mem.asBytes(&expirations).ptr,
        @sizeOf(u64),
    );
    const now = time.time(null);
    _ = time.localtime_r(&now, &globals.titlebarState.currentTime);
    updateTitlebarState(globals);
}

fn initializeTimerEvent(globals: *const Globals) EventSource {
    const fd: i32 = @intCast(linux.timerfd_create(linux.timerfd_clockid_t.MONOTONIC, .{}));

    var spec = linux.itimerspec{
        .it_interval = .{
            .sec = 1,
            .nsec = 0, // 0.5 s
        },
        .it_value = .{
            .sec = 1,
            .nsec = 0, // first expiration after 0.5 s
        },
    };

    _ = linux.timerfd_settime(fd, .{}, &spec, null);

    return .{ .fd = fd, .events = std.posix.POLL.IN, .dispatchFn = dispatchTimerEvent, .context = @ptrCast(@constCast(globals)) };
}

fn dispatchHyprlandEvent(event: *const EventSource) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const n = linux.read(event.fd, &buffer, buffer.len);

    if (n > 0) {
        std.debug.print("{s}", .{buffer[0..n]});
    }
}

fn initializeHyprlandEvent(init: std.process.Init) !EventSource { //print current workspace
    const xdg = init.environ_map.get("XDG_RUNTIME_DIR").?;
    const his = init.environ_map.get("HYPRLAND_INSTANCE_SIGNATURE").?;

    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    const path = try std.fmt.bufPrint(&addr.path, "{s}/hypr/{s}/.socket.sock", .{ xdg, his });
    addr.path[path.len] = 0;

    const hyprSockFd: i32 = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0));
    defer _ = linux.close(hyprSockFd);

    _ = linux.connect(hyprSockFd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un));
    const wbuffer = "j/activeworkspace";
    _ = linux.write(hyprSockFd, wbuffer, wbuffer.len);
    var rbuffer: [1000]u8 = undefined;
    const n = linux.read(hyprSockFd, &rbuffer, rbuffer.len);
    std.debug.print("{s}\n", .{rbuffer[0..n]});

    var addr2: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    const path2 = try std.fmt.bufPrint(&addr2.path, "{s}/hypr/{s}/.socket2.sock", .{ xdg, his });
    addr2.path[path2.len] = 0;

    const fd: i32 = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0));

    _ = linux.connect(fd, @ptrCast(&addr2), @sizeOf(linux.sockaddr.un));

    return .{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .dispatchFn = dispatchHyprlandEvent,
        .context = null,
    };
}

const Wayland = struct {
    const OutputFn = *const fn (wayland: *Wayland, output: *Output, data: ?*anyopaque) anyerror!void;

    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    shm: ?*wl.Shm,
    compositor: ?*wl.Compositor,
    layer_shell: ?*zwlr.LayerShellV1,
    outputs: std.ArrayList(Output),
    eventSources: std.ArrayList(EventSource),
    createOutputFn: OutputFn,
    updateOutputFn: OutputFn,
    destroyOutputFn: OutputFn,
    data: ?*anyopaque, //user data

    pub fn init(
        allocator: std.mem.Allocator,
        createOutputCallback: OutputFn,
        updateOutputCallback: OutputFn,
        destroyOutputCallback: OutputFn,
        data: ?*anyopaque, //user data
    ) !*Wayland {
        const display = try wl.Display.connect(null);
        const registry = try display.getRegistry();

        const self = try allocator.create(Wayland);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .shm = null,
            .compositor = null,
            .layer_shell = null,
            .outputs = std.ArrayList(Output).empty,
            .eventSources = std.ArrayList(EventSource).empty,
            .createOutputFn = createOutputCallback,
            .updateOutputFn = updateOutputCallback,
            .destroyOutputFn = destroyOutputCallback,
            .data = data,
        };

        registry.setListener(*Wayland, registryListener, self);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        return self;
    }

    pub fn registerEventSource(self: *Wayland, eventSource: EventSource) !void {
        try self.eventSources.append(self.allocator, eventSource);
    }

    pub fn runMainLoop(self: *Wayland) !void {
        const shm = self.shm orelse return error.NoWlShm;
        defer shm.destroy();
        const compositor = self.compositor orelse return error.NoWlCompositor;
        defer compositor.destroy();
        const layer_shell = self.layer_shell orelse return error.NoLayerShell;
        defer layer_shell.destroy();

        const wlFd: i32 = self.display.getFd();

        const sourceLen = self.eventSources.items.len;
        var fds = try self.allocator.alloc(std.posix.pollfd, sourceLen + 1);
        defer self.allocator.free(fds);

        while (true) { //TODO: add sig interrupt
            for (self.eventSources.items, 0..) |source, i| {
                fds[i] = .{
                    .fd = source.fd,
                    .events = source.events,
                    .revents = 0,
                };
            }
            fds[sourceLen] = .{
                .fd = wlFd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            };

            if (!self.display.prepareRead()) {
                _ = self.display.dispatchPending();
                continue;
            }

            _ = self.display.flush();

            _ = try std.posix.poll(fds, -1);

            const wayland_fd_ready = (fds[sourceLen].revents & std.posix.POLL.IN) != 0;
            if (wayland_fd_ready) {
                if (self.display.readEvents() != .SUCCESS)
                    return error.ReadFailed;
            } else {
                self.display.cancelRead();
            }

            _ = self.display.dispatchPending();

            for (self.eventSources.items, 0..) |source, i| {
                const fd_ready = (fds[i].revents & std.posix.POLL.IN) != 0;
                if (fd_ready) {
                    try source.dispatch();
                }
            }
        }

        for (self.eventSources.items) |source| {
            linux.close(source.fd);
        }
    }

    pub fn destroy(self: *Wayland) void {
        self.display.disconnect();
        self.registry.destroy();
        self.allocator.destroy(self);
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Wayland) void {
        switch (event) {
            .global => |global| {
                if (mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    self.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
                } else if (mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                    self.shm = registry.bind(global.name, wl.Shm, 1) catch return;
                } else if (mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                    self.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 1) catch return;
                } else if (mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                    const wlOutput = registry.bind(global.name, wl.Output, 4) catch {
                        std.debug.print("ERROR: failed to bind output", .{});
                        return;
                    };
                    self.outputs.append(self.allocator, .{
                        .output = wlOutput,
                        .name = global.name,
                    }) catch {
                        std.debug.print("ERROR: failed to add output to list", .{});
                        return;
                    };
                    const output = &self.outputs.items[self.outputs.items.len - 1];
                    wlOutput.setListener(*Wayland, outputListener, self);
                    std.debug.print("output {} has been created\n", .{output.name});
                    self.createOutputFn(self, output, self.data) catch {
                        //TODO: better error handling
                        std.debug.print("ERROR", .{});
                        return;
                    };
                }
            },
            .global_remove => |remove| {
                for (self.outputs.items, 0..) |o, i| {
                    if (o.name == remove.name) {
                        o.output.release();
                        var output = self.outputs.swapRemove(i);
                        std.debug.print("output {} is released\n", .{output.name});
                        self.destroyOutputFn(self, &output, self.data) catch {
                            //TODO: better error handling
                            std.debug.print("ERROR", .{});
                            return;
                        };
                        break;
                    }
                }
            },
        }
    }

    fn outputListener(wlOutput: *wl.Output, event: wl.Output.Event, self: *Wayland) void {
        const output: *Output = for (self.outputs.items, 0..) |o, i| {
            if (o.output == wlOutput)
                break &self.outputs.items[i];
        } else {
            @panic("Output not in output list");
        };

        switch (event) {
            .mode => |mode| {
                if (mode.flags.current) {
                    output.width = mode.width;
                    output.height = mode.height;
                }
            },
            .scale => |scale_event| {
                output.scale = scale_event.factor;
            },
            .geometry => {},
            .done => {
                output.done = true;
                std.debug.print("Output {} info updated:\n  size={}x{}\n  scale={}\n", .{ output.name, output.height, output.width, output.scale });
                self.updateOutputFn(self, output, self.data) catch {
                    //TODO: better error handling
                    std.debug.print("ERROR", .{});
                    return;
                };
            },
            else => {},
        }
    }

    pub const Output = struct {
        output: *wl.Output,
        name: u32, // the wl_registry global name, useful as a stable key
        width: i32 = 0,
        height: i32 = 0,
        scale: i32 = 1,
        done: bool = false, // set once compositor signals this output's info is complete
        data: ?*anyopaque = null, //user data
    };
};

fn outputCreate(wls: *Wayland, output: *Wayland.Output, data: ?*anyopaque) !void {
    const titlebarState: *TitlebarState = @ptrCast(@alignCast(data orelse @panic("Wayland data is null")));
    const titlebar = LayerSurface.create(wls.allocator, wls, output.output, 0, 30, 30, .top, .{ .top = true, .left = true, .right = true }, TitlebarState, drawTitlebar, titlebarState) catch {
        std.debug.print("ERROR CREATING TITLEBAR", .{});
        return;
    };
    output.data = titlebar;
}

fn outputUpdate(_: *Wayland, output: *Wayland.Output, _: ?*anyopaque) !void {
    const titlebar: *LayerSurface = @ptrCast(@alignCast(output.data orelse @panic("Wayland Output data is null")));
    titlebar.commit(output.scale);
}

fn outputDestroy(_: *Wayland, output: *Wayland.Output, _: ?*anyopaque) !void {
    const titlebar: *LayerSurface = @ptrCast(@alignCast(output.data orelse @panic("Wayland Output data is null")));
    titlebar.destroy();
}

pub fn main(init: std.process.Init) anyerror!void {
    // const display = try wl.Display.connect(null);
    // defer display.disconnect();
    // const registry = try display.getRegistry();
    // defer registry.destroy();

    var now: time.time_t = time.time(null);
    var tm: time.struct_tm = undefined;
    _ = time.localtime_r(&now, &tm);

    // var globals = Globals{
    //     .shm = null,
    //     .compositor = null,
    //     .layer_shell = null,
    //     .outputs = std.ArrayList(Output).empty,
    //     .allocator = std.heap.page_allocator,
    //     .titlebarState = TitlebarState{ .currentTime = tm },
    // };

    // registry.setListener(*Globals, registryListener, &globals);
    // if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // const shm = globals.shm orelse return error.NoWlShm;
    // defer shm.destroy();
    // const compositor = globals.compositor orelse return error.NoWlCompositor;
    // defer compositor.destroy();
    // const layer_shell = globals.layer_shell orelse return error.NoLayerShell;
    // defer layer_shell.destroy();

    // const wlFd: i32 = display.getFd();
    const allocator = std.heap.page_allocator;
    var titlebarState = TitlebarState{ .currentTime = tm };
    const wls = try Wayland.init(std.heap.page_allocator, outputCreate, outputUpdate, outputDestroy, @ptrCast(@constCast(&titlebarState)));
    defer wls.destroy();

    var globals = Globals{
        .allocator = allocator,
        .titlebarState = &titlebarState,
        .wayland = wls,
    };

    try globals.wayland.registerEventSource(try initializeHyprlandEvent(init));
    try globals.wayland.registerEventSource(initializeTimerEvent(&globals));

    try globals.wayland.runMainLoop();

    // while (true) {
    //     var fds = [_]std.posix.pollfd{ .{
    //         .fd = wlFd,
    //         .events = std.posix.POLL.IN,
    //         .revents = 0,
    //     }, .{
    //         .fd = timer.fd,
    //         .events = timer.events,
    //         .revents = 0,
    //     }, .{
    //         .fd = hyperland.fd,
    //         .events = hyperland.events,
    //         .revents = 0,
    //     } };

    //     if (!display.prepareRead()) {
    //         _ = display.dispatchPending();
    //         continue;
    //     }

    //     _ = display.flush();

    //     _ = try std.posix.poll(&fds, -1);
    //     const wayland_fd_ready = (fds[0].revents & std.posix.POLL.IN) != 0;
    //     const timer_fd_ready = (fds[1].revents & std.posix.POLL.IN) != 0;
    //     const hypr_fd_ready = (fds[2].revents & std.posix.POLL.IN) != 0;

    //     if (wayland_fd_ready) {
    //         if (display.readEvents() != .SUCCESS)
    //             return error.ReadFailed;
    //     } else {
    //         display.cancelRead();
    //     }

    //     _ = display.dispatchPending();

    //     if (timer_fd_ready) try timer.dispatch();
    //     if (hypr_fd_ready) try hyperland.dispatch();
    // }

    // linux.close(timer.fd);
    // linux.close(hyperland.fd);
}

fn updateTitlebarState(globals: *const Globals) void {
    for (globals.wayland.outputs.items) |output| {
        if (output.done) {
            const titlebar: *LayerSurface = @ptrCast(@alignCast(output.data orelse @panic("Wayland Output data is null")));
            titlebar.redraw();
        }
    }
}

const LayerSurface = struct {
    wayland: *Wayland,
    surface: *wl.Surface,
    layer_surface: *zwlr.LayerSurfaceV1,
    width: u32 = 0,
    height: u32 = 0,
    scale: u32 = 1,
    stride: u32 = 0,
    fd: ?posix.fd_t = null,
    data: ?[]align(std.heap.page_size_min) u8 = null,
    pool: ?*wl.ShmPool = null,
    buffers: [2]?*wl.Buffer = .{ null, null },
    buffer_released: [2]bool = .{ true, true },
    drawCallback: *const fn (surface: *const DrawableSurface, data: *anyopaque) void,
    drawData: *anyopaque,

    pub fn create(
        allocator: std.mem.Allocator,
        wls: *Wayland,
        output: ?*wl.Output,
        width: u32,
        height: u32,
        exclusiveZone: i32,
        layer: zwlr.LayerShellV1.Layer,
        anchor: zwlr.LayerSurfaceV1.Anchor,
        comptime DrawDataType: type,
        drawCallback: *const fn (surface: *const DrawableSurface, data: *DrawDataType) void,
        drawData: *DrawDataType,
    ) !*LayerSurface {
        const compositor = wls.compositor orelse @panic("no Compositor");
        const layer_shell = wls.layer_shell orelse @panic("no LayerShell");
        const surface = try compositor.createSurface();
        const layer_surface = try layer_shell.getLayerSurface(
            surface,
            output,
            layer,
            "hello-zig-wayland",
        );

        layer_surface.setAnchor(anchor);
        layer_surface.setSize(width, height);
        layer_surface.setExclusiveZone(exclusiveZone);

        const layerSurface = try allocator.create(LayerSurface);
        layerSurface.* = .{
            .wayland = wls,
            .surface = surface,
            .layer_surface = layer_surface,
            .drawCallback = @ptrCast(drawCallback),
            .drawData = @ptrCast(drawData),
        };

        layer_surface.setListener(*LayerSurface, layerSurfaceListener, layerSurface);
        return layerSurface;
    }

    pub fn commit(self: *LayerSurface, scale: i32) void {
        self.scale = @intCast(scale);
        self.surface.setBufferScale(scale);
        self.surface.commit();
    }

    pub fn destroy(self: *LayerSurface) void {
        self.layer_surface.destroy();
        self.surface.destroy();

        if (self.buffers[0]) |buffer| {
            buffer.destroy();
            self.buffers[0] = null;
        }
        if (self.buffers[1]) |buffer| {
            buffer.destroy();
            self.buffers[1] = null;
        }

        if (self.pool) |pool| {
            pool.destroy();
            self.pool = null;
        }

        if (self.data) |data| {
            posix.munmap(data);
            self.data = null;
        }

        if (self.fd) |fd| {
            _ = linux.close(fd);
            self.fd = null;
        }

        self.wayland.allocator.destroy(self);
    }

    pub fn redraw(self: *LayerSurface) void {
        var buffer: u32 = undefined;
        if (self.buffer_released[0]) {
            buffer = 0;
        } else if (self.buffer_released[1]) {
            buffer = 1;
        } else return;

        const s = DrawableSurface{
            .data = &(self.data.?)[self.stride * self.height * buffer],
            .format = cairo.CAIRO_FORMAT_ARGB32,
            .width = @intCast(self.width),
            .height = @intCast(self.height),
            .stride = @intCast(self.stride),
            .scale = self.scale,
        };
        self.drawCallback(&s, self.drawData);
        self.buffer_released[buffer] = false;
        self.surface.damageBuffer(0, 0, @intCast(self.width), @intCast(self.height));
        self.surface.attach(self.buffers[buffer].?, 0, 0);
        self.surface.commit();
    }

    fn layerSurfaceListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, self: *LayerSurface) void {
        switch (event) {
            .configure => |configure| {
                const shm = self.wayland.shm orelse return;

                self.width = configure.width * self.scale;
                self.height = configure.height * self.scale;
                self.layer_surface.ackConfigure(configure.serial);

                self.stride = self.width * 4;
                const size = self.stride * self.height;

                if (self.fd == null) {
                    self.fd = posix.memfd_create("hello-zig-wayland", 0) catch {
                        std.debug.print("ERROR: layersurface memfd create failed", .{});
                        return;
                    };
                }
                if (posix.errno(posix.system.ftruncate(self.fd.?, @intCast(size * 2))) != .SUCCESS) {
                    std.debug.print("layer surface listener truncate failed", .{});
                }

                if (self.data) |old| {
                    posix.munmap(old);
                    self.data = null;
                }
                self.data = posix.mmap(
                    null,
                    @intCast(size * 2),
                    .{ .READ = true, .WRITE = true },
                    .{ .TYPE = .SHARED },
                    self.fd.?,
                    0,
                ) catch {
                    std.debug.print("ERROR: layersurface memory map failed", .{});
                    return;
                };

                if (self.pool != null) {
                    (self.pool.?).destroy();
                    self.pool = null;
                }
                self.pool = shm.createPool(self.fd.?, @intCast(size * 2)) catch {
                    std.debug.print("ERROR: layersurface create shm pool failed", .{});
                    return;
                };

                if (self.buffers[0]) |buffer| {
                    buffer.destroy();
                }
                if (self.buffers[1]) |buffer| {
                    buffer.destroy();
                }
                self.buffers[0] = self.pool.?.createBuffer(0, @intCast(self.width), @intCast(self.height), @intCast(self.stride), wl.Shm.Format.argb8888) catch {
                    std.debug.print("ERROR: layersurface create buffer failed", .{});
                    return;
                };
                self.buffers[1] = self.pool.?.createBuffer(@intCast(size), @intCast(self.width), @intCast(self.height), @intCast(self.stride), wl.Shm.Format.argb8888) catch {
                    std.debug.print("ERROR: layersurface create buffer failed", .{});
                    return;
                };

                self.buffers[0].?.setListener(*LayerSurface, buffer0, self);
                self.buffers[1].?.setListener(*LayerSurface, buffer1, self);

                self.redraw();
            },
            .closed => {},
        }
    }

    fn buffer0(_: *wl.Buffer, event: wl.Buffer.Event, self: *LayerSurface) void {
        switch (event) {
            .release => {
                self.buffer_released[0] = true;
            },
        }
    }

    fn buffer1(_: *wl.Buffer, event: wl.Buffer.Event, self: *LayerSurface) void {
        switch (event) {
            .release => {
                self.buffer_released[1] = true;
            },
        }
    }
};

fn drawTitlebar(surface: *const DrawableSurface, state: *const TitlebarState) void {
    const s: f64 = @floatFromInt(surface.scale);

    var buf: [32]u8 = undefined;
    const len = time.strftime(
        &buf[0],
        buf.len,
        "%H:%M:%S %d.%m.%Y",
        &state.currentTime,
    );
    const timeStr = buf[0..len];

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
    cairo.cairo_show_text(cr, &timeStr[0]);
    // --- end draw ---

    cairo.cairo_surface_flush(cairo_surface); // ensure Cairo's writes are done before Wayland reads the buffer
}
