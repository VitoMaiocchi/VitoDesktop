const std = @import("std");
const linux = std.os.linux;

const EventSource = @import("../types.zig").EventSource;

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

pub fn init() !EventSource {
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

pub fn cleanup() void {
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
