const std = @import("std");
const linux = std.os.linux;
const EventSource = @import("../types.zig").EventSource;

const dbus = @cImport({
    @cInclude("dbus/dbus.h");
});

const NMState = enum(u32) {
    unknown = 0,
    asleep = 10,
    disconnected = 20,
    disconnecting = 30,
    connecting = 40,
    connected_local = 50, // link-local only, e.g. no DHCP yet
    connected_site = 60, // connected, but no internet route confirmed
    connected_global = 70, // fully connected with internet access
    _,

    pub fn fromRaw(raw: u32) NMState {
        return @enumFromInt(raw);
    }

    pub fn isConnected(self: NMState) bool {
        return switch (self) {
            .connected_local, .connected_site, .connected_global => true,
            else => false,
        };
    }

    pub fn label(self: NMState) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .asleep => "asleep",
            .disconnected => "disconnected",
            .disconnecting => "disconnecting",
            .connecting => "connecting",
            .connected_local => "connected (local only)",
            .connected_site => "connected (site only)",
            .connected_global => "connected",
            _ => "invalid",
        };
    }
};

pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    eventSource: *const EventSource,
    // callback: *const fn (c_long, *anyopaque) void,
    // data: *anyopaque,
    connection: *dbus.struct_DBusConnection,

    // pub fn create(allocator: std.mem.Allocator, T: type, callback: *const fn (c_long, *T) void, data: *T ) !*const NetworkManager {
    pub fn create(allocator: std.mem.Allocator) !*const NetworkManager {
        const conn = dbus.dbus_bus_get(dbus.DBUS_BUS_SYSTEM, null) orelse return error.DBusConnect;

        // initial state
        {
            const msg = dbus.dbus_message_new_method_call(
                "org.freedesktop.NetworkManager",
                "/org/freedesktop/NetworkManager",
                "org.freedesktop.NetworkManager",
                "state",
            ) orelse return error.OutOfMemory;
            defer dbus.dbus_message_unref(msg);

            const reply = dbus.dbus_connection_send_with_reply_and_block(conn, msg, -1, null) orelse
                return error.DBusCall;
            defer dbus.dbus_message_unref(reply);

            var state: u32 = 0;
            if (dbus.dbus_message_get_args(reply, null, dbus.DBUS_TYPE_UINT32, &state, dbus.DBUS_TYPE_INVALID) == 0)
                return error.BadReply;
            std.debug.print("NetworkManager state: {s}\n", .{NMState.fromRaw(state).label()});
        }

        // subscribe to StateChanged signals
        dbus.dbus_bus_add_match(
            conn,
            "type='signal',interface='org.freedesktop.NetworkManager',member='StateChanged'",
            null,
        );
        dbus.dbus_connection_flush(conn);

        var fd: c_int = -1;
        if (dbus.dbus_connection_get_unix_fd(conn, &fd) == 0)
            return error.NoFd;

        const eventSource = try allocator.create(EventSource);
        const self = try allocator.create(NetworkManager);

        self.* = .{
            .allocator = allocator,
            .eventSource = eventSource,
            // .data = data,
            // .callback = @ptrCast(callback),
            .connection = conn,
        };

        eventSource.* = .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .dispatchFn = dispatch,
            .context = @ptrCast(@constCast(self)),
        };

        return self;
    }

    fn dispatch(event: *const EventSource) anyerror!void {
        const self: *NetworkManager = @ptrCast(@alignCast(event.context.?));

        // read whatever's waiting on the socket into dbus's internal queue
        _ = dbus.dbus_connection_read_write(self.connection, 0);

        // pop and dispatch every message that arrived
        var msg = dbus.dbus_connection_pop_message(self.connection);
        while (msg != null) : (msg = dbus.dbus_connection_pop_message(self.connection)) {
            defer dbus.dbus_message_unref(msg);

            if (dbus.dbus_message_is_signal(msg, "org.freedesktop.NetworkManager", "StateChanged") != 0) {
                var state: u32 = 0;
                if (dbus.dbus_message_get_args(msg, null, dbus.DBUS_TYPE_UINT32, &state, dbus.DBUS_TYPE_INVALID) != 0) {
                    std.debug.print("NetworkManager state changed: {s}\n", .{NMState.fromRaw(state).label()});
                }
            }
        }
    }

    pub fn destroy(self: *const NetworkManager) void {
        _ = linux.close(self.eventSource.fd);
        self.allocator.destroy(self.eventSource);
        self.allocator.destroy(self);
    }
};
