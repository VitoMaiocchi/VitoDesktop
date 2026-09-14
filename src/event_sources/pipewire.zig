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

pub const PipeWire = struct {
    eventSource: *const EventSource,
    allocator: std.mem.Allocator,

    pw_main_loop: *pipewire.struct_pw_main_loop,
    pw_loop: *pipewire.struct_pw_loop,
    pw_context: *pipewire.struct_pw_context,
    pw_core: *pipewire.struct_pw_core,
    pw_registry: *pipewire.struct_pw_registry,

    pw_registry_listener: pipewire.struct_spa_hook = undefined,
    pw_registry_events: pipewire.struct_pw_registry_events = .{
        .version = pipewire.PW_VERSION_REGISTRY_EVENTS,
        .global = registryCallback,
    },

    metadata_listener: pipewire.struct_spa_hook = undefined,
    metadata_events: pipewire.struct_pw_metadata_events = .{
        .version = pipewire.PW_VERSION_METADATA_EVENTS,
        .property = defaultCallback,
    },

    defaultAudioSink: ?[]const u8 = null,
    nodes: std.StringHashMap(u32),
    defaultAudioSinkId: ?u32 = null,

    fn setDefaultSinkId(self: *PipeWire, id: u32) void {
        self.defaultAudioSinkId = id;
        //std.debug.print("DEFAULT SINK ID = {}\n", .{self.defaultAudioSinkId.?});
    }

    fn defaultCallback(
        data: ?*anyopaque,
        _: u32,
        key: [*c]const u8,
        _: [*c]const u8,
        value: [*c]const u8,
    ) callconv(.c) c_int {
        const self: *PipeWire = @ptrCast(@alignCast(data.?));

        if (std.mem.eql(u8, std.mem.span(key), "default.audio.sink")) {
            const v = std.mem.span(value);

            // v is JSON: {"name":"..."}
            //std.debug.print("default output = {s}\n", .{v});

            const parsed = std.json.parseFromSlice(
                struct { name: []const u8 },
                std.heap.page_allocator,
                v,
                .{},
            ) catch return 0;
            defer parsed.deinit();

            //std.debug.print("default name = \"{s}\" \n", .{parsed.value.name});

            self.defaultAudioSink = std.heap.page_allocator.dupe(u8, parsed.value.name) catch return 0;
            if (self.defaultAudioSinkId == null) {
                if (self.nodes.get(parsed.value.name)) |id| {
                    self.setDefaultSinkId(id);
                }
            }
        }

        return 0;
    }

    fn registryCallback(
        data: ?*anyopaque,
        id: u32,
        _: u32,
        @"type": [*c]const u8,
        _: u32,
        props: [*c]const pipewire.struct_spa_dict,
    ) callconv(.c) void {
        const self: *PipeWire = @ptrCast(@alignCast(data.?));

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

            const registry = self.pw_registry;
            const metadata_ptr = pipewire.pw_registry_bind(
                registry,
                id,
                pipewire.PW_TYPE_INTERFACE_Metadata,
                pipewire.PW_VERSION_METADATA,
                0,
            );

            if (metadata_ptr == null) return;

            const metadata: *pipewire.struct_pw_metadata = @ptrCast(metadata_ptr.?);

            _ = pipewire.pw_metadata_add_listener(
                metadata,
                &self.metadata_listener,
                &self.metadata_events,
                self,
            );
        }

        if (std.mem.eql(u8, std.mem.span(@"type"), pipewire.PW_TYPE_INTERFACE_Node)) {
            if (props == null) return;

            const dict = props.*;
            for (dict.items[0..dict.n_items]) |item| {
                if (std.mem.eql(u8, std.mem.span(item.key), "node.name")) {
                    const node_name: []const u8 = std.mem.span(item.value);
                    //std.debug.print("node: {s}, id: {}\n", .{ node_name, id });

                    if (self.defaultAudioSink != null) {
                        if (std.mem.eql(u8, self.defaultAudioSink.?, node_name)) {
                            self.setDefaultSinkId(id);
                        }
                    }

                    const name_copy = std.heap.page_allocator.dupe(u8, node_name) catch return;

                    self.nodes.put(name_copy, id) catch return;
                }
            }
        }
    }

    pub fn create(allocator: std.mem.Allocator) !*PipeWire {
        pw_init(null, null);

        const pw_main_loop = pipewire.pw_main_loop_new(null);
        if (pw_main_loop == null) return error.PipeWireLoopFailed;

        const pw_loop = pipewire.pw_main_loop_get_loop(pw_main_loop.?);

        const pw_context = pipewire.pw_context_new(pw_loop.?, null, 0);
        if (pw_context == null) return error.PipeWireContextFailed;

        const pw_core = pipewire.pw_context_connect(pw_context.?, null, 0);
        if (pw_core == null) return error.PipeWireConnectionFailed;

        const pw_registry = pipewire.pw_core_get_registry(
            pw_core.?,
            pipewire.PW_VERSION_REGISTRY,
            0,
        );
        if (pw_registry == null) return error.PipeWireRegistyFailed;

        const eventSource = try allocator.create(EventSource);
        const self = try allocator.create(PipeWire);

        self.* = .{
            .allocator = allocator,
            .eventSource = eventSource,
            .pw_main_loop = pw_main_loop.?,
            .pw_loop = pw_loop,
            .pw_context = pw_context.?,
            .pw_core = pw_core.?,
            .pw_registry = pw_registry.?,
            .nodes = std.StringHashMap(u32).init(allocator),
        };

        _ = pipewire.pw_registry_add_listener(
            pw_registry.?,
            &self.pw_registry_listener,
            &self.pw_registry_events,
            self,
        );

        eventSource.* = .{
            .fd = pipewire.pw_loop_get_fd(pw_loop.?),
            .events = std.posix.POLL.IN,
            .dispatchFn = dispatch,
            .context = pw_loop.?,
        };

        return self;
    }

    pub fn destroy(self: *const PipeWire) void {
        _ = pipewire.pw_registry_destroy(self.pw_registry, 0);
        _ = pipewire.pw_core_disconnect(self.pw_core);
        pipewire.pw_context_destroy(self.pw_context);
        pipewire.pw_main_loop_destroy(self.pw_main_loop);
        pw_deinit();

        _ = linux.close(self.eventSource.fd);
        self.allocator.destroy(self.eventSource);
        self.allocator.destroy(self);
    }

    fn dispatch(event: *const EventSource) anyerror!void {
        if (event.context == null) return;
        const loop: *pipewire.struct_pw_loop = @ptrCast(@alignCast(event.context.?));
        _ = pipewire.pw_loop_iterate(loop, 0);
    }
};
