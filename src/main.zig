const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;

const Wayland = @import("wayland.zig").Wayland;
const LayerSurface = @import("wayland.zig").LayerSurface;

const EventSource = @import("types.zig").EventSource;
const DrawableSurface = @import("types.zig").DrawableSurface;

const cairo = @cImport({
    @cInclude("cairo/cairo.h");
});

const time = @cImport({
    @cInclude("time.h");
});

const pipewire = @cImport({
    @cInclude("pipewire/context.h");
    @cInclude("pipewire/core.h");
    @cInclude("pipewire/stream.h");
    @cInclude("pipewire/node.h");
    @cInclude("pipewire/main-loop.h");
    @cInclude("pipewire/extensions/metadata.h");
});

extern fn pw_init(argc: ?*c_int, argv: ?*?[*:0]u8) void;
extern fn pw_deinit() void;

var defaultAudioSink: ?[]const u8 = null;
var nodes = std.StringHashMap(u32).init(std.heap.page_allocator);
var defaultAudioSinkId: ?u32 = null;

fn defaultCallback(
    _: ?*anyopaque,
    _: u32,
    key: [*c]const u8,
    _: [*c]const u8,
    value: [*c]const u8,
) callconv(.c) c_int {
    if (std.mem.eql(u8, std.mem.span(key), "default.audio.sink")) {
        const v = std.mem.span(value);

        // v is JSON: {"name":"..."}
        std.debug.print("default output = {s}\n", .{v});

        const parsed = std.json.parseFromSlice(
            struct { name: []const u8 },
            std.heap.page_allocator,
            v,
            .{},
        ) catch return 0;
        defer parsed.deinit();

        std.debug.print("default name = \"{s}\" \n", .{parsed.value.name});

        defaultAudioSink = std.heap.page_allocator.dupe(u8, parsed.value.name) catch return 0;
        if (defaultAudioSinkId == null) {
            if (nodes.get(parsed.value.name)) |id| {
                defaultAudioSinkId = id;
                std.debug.print("DEFAULT SINK ID = {}\n", .{defaultAudioSinkId.?});
            }
        }
    }

    return 0;
}

var metadata_listener: pipewire.struct_spa_hook = undefined;

var metadata_events = pipewire.struct_pw_metadata_events{
    .version = pipewire.PW_VERSION_METADATA_EVENTS,
    .property = defaultCallback,
};

fn registryCallback(
    data: ?*anyopaque,
    id: u32,
    _: u32,
    @"type": [*c]const u8,
    _: u32,
    props: [*c]const pipewire.struct_spa_dict,
) callconv(.c) void {
    if (std.mem.eql(
        u8,
        std.mem.span(@"type"),
        pipewire.PW_TYPE_INTERFACE_Metadata,
    )) {
        var is_default = false;
        if (props != null) {
            const dict = props.*;
            for (dict.items[0..dict.n_items]) |item| {
                if (std.mem.eql(u8, std.mem.span(item.key), "metadata.name") and
                    std.mem.eql(u8, std.mem.span(item.value), "default"))
                {
                    is_default = true;
                }
            }
        }

        if (!is_default) return;

        const registry: *pipewire.struct_pw_registry = @ptrCast(@alignCast(data.?));
        const metadata_ptr = pipewire.pw_registry_bind(
            registry,
            id,
            pipewire.PW_TYPE_INTERFACE_Metadata,
            pipewire.PW_VERSION_METADATA,
            0,
        );

        if (metadata_ptr == null) return;

        const metadata: *pipewire.struct_pw_metadata = @ptrCast(metadata_ptr.?);

        _ = pipewire.pw_metadata_add_listener(metadata, &metadata_listener, &metadata_events, null);
    }

    if (std.mem.eql(u8, std.mem.span(@"type"), pipewire.PW_TYPE_INTERFACE_Node)) {
        if (props == null) return;

        const dict = props.*;
        for (dict.items[0..dict.n_items]) |item| {
            if (std.mem.eql(u8, std.mem.span(item.key), "node.name")) {
                const node_name: []const u8 = std.mem.span(item.value);
                std.debug.print("node: {s}, id: {}\n", .{ node_name, id });

                if (defaultAudioSink != null) {
                    if (std.mem.eql(u8, defaultAudioSink.?, node_name)) {
                        defaultAudioSinkId = id;
                        std.debug.print("DEFAULT SINK ID = {}\n", .{defaultAudioSinkId.?});
                    }
                }

                const name_copy = std.heap.page_allocator.dupe(u8, node_name) catch return;

                nodes.put(name_copy, id) catch return;
            }
        }
    }
}

fn dispatchPipeWire(event: *const EventSource) anyerror!void {
    if (event.context == null) return;
    const loop: *pipewire.struct_pw_loop = @ptrCast(@alignCast(event.context.?));
    _ = pipewire.pw_loop_iterate(loop, 0);
}

var pw_main_loop: ?*pipewire.struct_pw_main_loop = null;
var pw_loop: ?*pipewire.struct_pw_loop = null;
var pw_context: ?*pipewire.struct_pw_context = null;
var pw_core: ?*pipewire.struct_pw_core = null;
var pw_registry: ?*pipewire.struct_pw_registry = null;

var pw_registry_listener: pipewire.struct_spa_hook = undefined;
var pw_registry_events = pipewire.struct_pw_registry_events{
    .version = pipewire.PW_VERSION_REGISTRY_EVENTS,
    .global = registryCallback,
};

fn initializePipeWire() !EventSource {
    pw_init(null, null);

    pw_main_loop = pipewire.pw_main_loop_new(null);
    if (pw_main_loop == null) return error.PipeWireLoopFailed;

    pw_loop = pipewire.pw_main_loop_get_loop(pw_main_loop.?);

    pw_context = pipewire.pw_context_new(pw_loop.?, null, 0);
    if (pw_context == null) return error.PipeWireContextFailed;

    pw_core = pipewire.pw_context_connect(pw_context.?, null, 0);
    if (pw_core == null) return error.PipeWireConnectionFailed;

    std.debug.print("Connected to PipeWire\n", .{});

    pw_registry = pipewire.pw_core_get_registry(
        pw_core.?,
        pipewire.PW_VERSION_REGISTRY,
        0,
    );

    _ = pipewire.pw_registry_add_listener(
        pw_registry.?,
        &pw_registry_listener,
        &pw_registry_events,
        pw_registry.?,
    );

    return .{
        .fd = pipewire.pw_loop_get_fd(pw_loop.?),
        .events = std.posix.POLL.IN,
        .dispatchFn = dispatchPipeWire,
        .context = pw_loop.?,
    };
}

fn cleanupPipeWire() void {
    if (pw_registry) |registry| {
        _ = pipewire.pw_registry_destroy(registry, 0);
    }
    if (pw_core) |core| {
        _ = pipewire.pw_core_disconnect(core);
    }
    if (pw_context) |context| {
        pipewire.pw_context_destroy(context);
    }
    if (pw_main_loop) |main_loop| {
        pipewire.pw_main_loop_destroy(main_loop);
    }

    pw_deinit();
}

// fn pipewireHello() !void {
//     pw_init(null, null);
//     defer pw_deinit();

//     const loop = pipewire.pw_main_loop_new(null);
//     defer pipewire.pw_main_loop_destroy(loop);

//     const context = pipewire.pw_context_new(pipewire.pw_main_loop_get_loop(loop), null, 0);
//     defer pipewire.pw_context_destroy(context);

//     const core = pipewire.pw_context_connect(context, null, 0);
//     if (core == null) {
//         return error.PipeWireConnectionFailed;
//     }
//     defer _ = pipewire.pw_core_disconnect(core);

//     std.debug.print("Connected to PipeWire\n", .{});

//     const registry = pipewire.pw_core_get_registry(core, pipewire.PW_VERSION_REGISTRY, 0);
//     defer _ = pipewire.pw_registry_destroy(registry, 0);

//     var listener: pipewire.struct_spa_hook = undefined;

//     var events = pipewire.struct_pw_registry_events{
//         .version = pipewire.PW_VERSION_REGISTRY_EVENTS,
//         .global = registryCallback,
//     };

//     _ = pipewire.pw_registry_add_listener(registry, &listener, &events, registry);

//     _ = pipewire.pw_main_loop_run(loop);
// }

const Globals = struct {
    allocator: std.mem.Allocator,
    titlebarState: *TitlebarState,
    wayland: *Wayland,
};

const TitlebarState = struct {
    currentTime: time.struct_tm,
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
    var now: time.time_t = time.time(null);
    var tm: time.struct_tm = undefined;
    _ = time.localtime_r(&now, &tm);

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
    try globals.wayland.registerEventSource(try initializePipeWire());
    defer cleanupPipeWire();

    try globals.wayland.runMainLoop();
}

fn updateTitlebarState(globals: *const Globals) void {
    for (globals.wayland.outputs.items) |output| {
        if (output.done) {
            const titlebar: *LayerSurface = @ptrCast(@alignCast(output.data orelse @panic("Wayland Output data is null")));
            titlebar.redraw();
        }
    }
}

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
