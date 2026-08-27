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
