const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;

const Wayland = @import("wayland.zig").Wayland;
const LayerSurface = @import("wayland.zig").LayerSurface;

const DrawableSurface = @import("types.zig").DrawableSurface;
const EventSource = @import("types.zig").EventSource;

const Hyprland = @import("event_sources/hyprland.zig").Hyprland;
const PipeWire = @import("event_sources/pipewire.zig").PipeWire;
const Timer = @import("event_sources/timer.zig").Timer;

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

fn timeCallback(now: c_long, globals: *Globals) void {
    _ = time.localtime_r(&now, &globals.titlebarState.currentTime);
    updateTitlebarState(globals);
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

    const hyprland = try Hyprland.create(allocator, init);
    defer hyprland.destroy();

    const timer = try Timer.create(allocator, Globals, timeCallback, &globals);
    defer timer.destroy();

    const pipewire = try PipeWire.create(allocator);
    defer pipewire.destroy();

    try globals.wayland.registerEventSource(hyprland.eventSource);
    try globals.wayland.registerEventSource(timer.eventSource);
    try globals.wayland.registerEventSource(pipewire.eventSource);

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
