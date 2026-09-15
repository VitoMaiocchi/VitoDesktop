const std = @import("std");
const mem = std.mem;
const posix = std.posix;
const linux = std.os.linux;

const Wayland = @import("wayland.zig").Wayland;
const LayerSurface = @import("wayland.zig").LayerSurface;

const DrawableSurface = @import("types.zig").DrawableSurface;
const EventSource = @import("types.zig").EventSource;
const Format = @import("types.zig").Format;

const Hyprland = @import("event_sources/hyprland.zig").Hyprland;
const PipeWire = @import("event_sources/pipewire.zig").PipeWire;
const Timer = @import("event_sources/timer.zig").Timer;
const NetworkManager = @import("event_sources/networkmanager.zig").NetworkManager;

const NetworkStatus = @import("event_sources/networkmanager.zig").NetworkStatus;

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
    activeWindow: [256]u8 = undefined,
    activeWindowLen: usize = 0,
    volume: u32 = 0,
};

fn timeCallback(now: c_long, globals: *Globals) void {
    _ = time.localtime_r(&now, &globals.titlebarState.currentTime);
    updateTitlebarState(globals);
}

fn outputCreate(wls: *Wayland, output: *Wayland.Output, data: ?*anyopaque) !void {
    const titlebarState: *TitlebarState = @ptrCast(@alignCast(data orelse @panic("Wayland data is null")));
    const titlebar = LayerSurface.create(
        wls.allocator,
        wls,
        output.output,
        0,
        30,
        30,
        .top,
        .{ .top = true, .left = true, .right = true },
        TitlebarState,
        drawTitlebar,
        titlebarState,
    ) catch {
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

fn activeMonitorCallback(title: []const u8, globals: *Globals) void {
    const state: *TitlebarState = globals.titlebarState;

    const len = @min(title.len, state.activeWindow.len);
    @memcpy(state.activeWindow[0..len], title[0..len]);
    state.activeWindowLen = len;

    updateTitlebarState(globals);
}

fn volumeCallback(volume: u32, globals: *Globals) void {
    const state: *TitlebarState = globals.titlebarState;
    state.volume = volume;
    updateTitlebarState(globals);
}

fn networkCallback(status: *NetworkStatus, globals: *Globals) void {
    switch (status.kind) {
        .wifi => {
            const ssid = status.ssidSlice();
            const ip = status.ipSlice();
            if (status.wifi_quality) |q| {
                std.debug.print("Network: wifi ({s}, {d}%) ip={s}\n", .{ ssid, q, ip });
            } else {
                std.debug.print("Network: wifi ({s}) ip={s}\n", .{ ssid, ip });
            }
        },
        .ethernet => std.debug.print("Network: ethernet ip={s}\n", .{status.ipSlice()}),
        else => std.debug.print("Network: {s}\n", .{status.label()}),
    }
    _ = globals;
}

pub fn main(init: std.process.Init) anyerror!void {
    var now: time.time_t = time.time(null);
    var tm: time.struct_tm = undefined;
    _ = time.localtime_r(&now, &tm);

    const allocator = std.heap.page_allocator;
    var titlebarState: TitlebarState = .{ .currentTime = tm };
    const wls = try Wayland.init(
        std.heap.page_allocator,
        outputCreate,
        outputUpdate,
        outputDestroy,
        @ptrCast(@constCast(&titlebarState)),
    );
    defer wls.destroy();

    var globals = Globals{
        .allocator = allocator,
        .titlebarState = &titlebarState,
        .wayland = wls,
    };

    const hyprland = try Hyprland.create(
        allocator,
        init,
        Globals,
        activeMonitorCallback,
        &globals,
    );
    defer hyprland.destroy();

    const timer = try Timer.create(
        allocator,
        Globals,
        timeCallback,
        &globals,
    );
    defer timer.destroy();

    const pipewire = try PipeWire.create(
        allocator,
        Globals,
        volumeCallback,
        &globals,
    );
    defer pipewire.destroy();

    const networkmanager = try NetworkManager.create(
        allocator,
        Globals,
        networkCallback,
        &globals,
    );
    defer networkmanager.destroy();

    try globals.wayland.registerEventSource(hyprland.eventSource);
    try globals.wayland.registerEventSource(timer.eventSource);
    try globals.wayland.registerEventSource(pipewire.eventSource);
    try globals.wayland.registerEventSource(networkmanager.eventSource);

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

    //Convert to null teminiated c strings
    var timeBuf: [32:0]u8 = undefined;
    const timeLen = time.strftime(
        &timeBuf,
        timeBuf.len,
        "%H:%M:%S %d.%m.%Y",
        &state.currentTime,
    );
    timeBuf[timeLen] = 0;

    var activeBuf: [256:0]u8 = undefined;
    const activeLen = @min(state.activeWindowLen, activeBuf.len - 1);
    @memcpy(activeBuf[0..activeLen], state.activeWindow[0..activeLen]);
    activeBuf[activeLen] = 0;

    var volumeBuf: [32:0]u8 = undefined;
    const volumeSlice = std.fmt.bufPrint(&volumeBuf, "Volume: {d}%", .{state.volume}) catch "?%";
    volumeBuf[volumeSlice.len] = 0;

    const format = switch (surface.format) {
        Format.ARGB8888 => cairo.CAIRO_FORMAT_ARGB32,
    };

    // Wrap the mmap'd memory as a Cairo surface — no copy, same bytes.
    const cairo_surface = cairo.cairo_image_surface_create_for_data(
        surface.data,
        format,
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
    cairo.cairo_show_text(cr, &timeBuf);

    cairo.cairo_move_to(cr, 200 * s, 25 * s);
    cairo.cairo_show_text(cr, &volumeBuf);

    cairo.cairo_move_to(cr, 350 * s, 25 * s);
    cairo.cairo_show_text(cr, &activeBuf);
    // --- end draw ---

    cairo.cairo_surface_flush(cairo_surface); // ensure Cairo's writes are done before Wayland reads the buffer
}
