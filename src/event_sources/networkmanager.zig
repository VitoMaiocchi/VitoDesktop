const std = @import("std");
const EventSource = @import("../types.zig").EventSource;

const dbus = @cImport({
    @cInclude("dbus/dbus.h");
});

//AI SLOP CODE

const NM_DEVICE_ETHERNET: u32 = 1;
const NM_DEVICE_WIFI: u32 = 2;

const NM_DEVICE_PREPARE: u32 = 40;
const NM_DEVICE_CONFIG: u32 = 50;
const NM_DEVICE_NEED_AUTH: u32 = 60;
const NM_DEVICE_IP_CONFIG: u32 = 70;
const NM_DEVICE_IP_CHECK: u32 = 80;
const NM_DEVICE_SECONDARIES: u32 = 90;
const NM_DEVICE_ACTIVATED: u32 = 100;

pub const NetworkStatus = struct {
    pub const Kind = enum {
        disconnected,
        connecting_wifi,
        connecting_ethernet,
        wifi,
        ethernet,
    };

    kind: Kind,

    ssid: [64]u8 = undefined,
    ssid_len: usize = 0,

    pub fn ssidSlice(self: *const NetworkStatus) []const u8 {
        return self.ssid[0..self.ssid_len];
    }

    pub fn label(self: *const NetworkStatus) []const u8 {
        return switch (self.kind) {
            .disconnected => "disconnected",
            .connecting_wifi => "connecting wifi",
            .connecting_ethernet => "connecting ethernet",
            .wifi => "wifi",
            .ethernet => "ethernet",
        };
    }
};

pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    eventSource: *EventSource,
    connection: *dbus.struct_DBusConnection,

    status: NetworkStatus,

    pub fn create(allocator: std.mem.Allocator) !*NetworkManager {
        const connection =
            dbus.dbus_bus_get(
                dbus.DBUS_BUS_SYSTEM,
                null,
            ) orelse return error.DBusConnect;

        const self = try allocator.create(NetworkManager);
        errdefer allocator.destroy(self);

        const eventSource = try allocator.create(EventSource);
        errdefer allocator.destroy(eventSource);

        self.* = .{
            .allocator = allocator,
            .eventSource = eventSource,
            .connection = connection,
            .status = .{
                .kind = .disconnected,
            },
        };

        dbus.dbus_bus_add_match(
            connection,
            "type='signal',interface='org.freedesktop.NetworkManager',member='StateChanged'",
            null,
        );

        dbus.dbus_bus_add_match(
            connection,
            "type='signal',interface='org.freedesktop.NetworkManager.Device',member='StateChanged'",
            null,
        );

        dbus.dbus_bus_add_match(
            connection,
            "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'",
            null,
        );

        dbus.dbus_connection_flush(connection);

        var fd: c_int = -1;

        if (dbus.dbus_connection_get_unix_fd(
            connection,
            &fd,
        ) == 0) {
            dbus.dbus_connection_unref(connection);
            return error.NoFd;
        }

        eventSource.* = .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .dispatchFn = dispatch,
            .context = @ptrCast(self),
        };

        try self.refresh();

        return self;
    }

    fn dispatch(event: *const EventSource) anyerror!void {
        const self: *NetworkManager =
            @ptrCast(@alignCast(event.context.?));

        _ = dbus.dbus_connection_read_write(
            self.connection,
            0,
        );

        var msg =
            dbus.dbus_connection_pop_message(
                self.connection,
            );

        while (msg != null) {
            const current_msg = msg.?;

            defer dbus.dbus_message_unref(current_msg);

            const is_nm_state =
                dbus.dbus_message_is_signal(
                    current_msg,
                    "org.freedesktop.NetworkManager",
                    "StateChanged",
                ) != 0;

            const is_device_state =
                dbus.dbus_message_is_signal(
                    current_msg,
                    "org.freedesktop.NetworkManager.Device",
                    "StateChanged",
                ) != 0;

            const is_properties_changed =
                dbus.dbus_message_is_signal(
                    current_msg,
                    "org.freedesktop.DBus.Properties",
                    "PropertiesChanged",
                ) != 0;

            if (is_nm_state or is_device_state or is_properties_changed) {
                self.refresh() catch |err| {
                    std.log.err(
                        "NetworkManager refresh failed: {}",
                        .{err},
                    );
                };
            }

            msg = dbus.dbus_connection_pop_message(
                self.connection,
            );
        }
    }

    fn refresh(self: *NetworkManager) !void {
        const reply = try self.callMethod(
            "/org/freedesktop/NetworkManager",
            "org.freedesktop.NetworkManager",
            "GetDevices",
        );
        defer dbus.dbus_message_unref(reply);

        var iter: dbus.DBusMessageIter = undefined;

        if (dbus.dbus_message_iter_init(
            reply,
            &iter,
        ) == 0) {
            return error.BadReply;
        }

        if (dbus.dbus_message_iter_get_arg_type(
            &iter,
        ) != dbus.DBUS_TYPE_ARRAY) {
            return error.BadReply;
        }

        var array: dbus.DBusMessageIter = undefined;

        dbus.dbus_message_iter_recurse(
            &iter,
            &array,
        );

        var wifi_connected: ?[*:0]const u8 = null;
        var ethernet_connected = false;

        var wifi_connecting = false;
        var ethernet_connecting = false;

        while (dbus.dbus_message_iter_get_arg_type(
            &array,
        ) != dbus.DBUS_TYPE_INVALID) {
            var device_path: [*:0]const u8 = undefined;

            dbus.dbus_message_iter_get_basic(
                &array,
                @as(?*anyopaque, @ptrCast(&device_path)),
            );

            const device_type =
                self.getU32Property(
                    device_path,
                    "org.freedesktop.NetworkManager.Device",
                    "DeviceType",
                ) catch {
                    _ = dbus.dbus_message_iter_next(&array);
                    continue;
                };

            const state =
                self.getU32Property(
                    device_path,
                    "org.freedesktop.NetworkManager.Device",
                    "State",
                ) catch {
                    _ = dbus.dbus_message_iter_next(&array);
                    continue;
                };

            const connecting =
                state >= NM_DEVICE_PREPARE and
                state <= NM_DEVICE_SECONDARIES;

            switch (device_type) {
                NM_DEVICE_WIFI => {
                    if (state == NM_DEVICE_ACTIVATED) {
                        wifi_connected = device_path;
                    } else if (connecting) {
                        wifi_connecting = true;
                    }
                },

                NM_DEVICE_ETHERNET => {
                    if (state == NM_DEVICE_ACTIVATED) {
                        ethernet_connected = true;
                    } else if (connecting) {
                        ethernet_connecting = true;
                    }
                },

                else => {},
            }

            _ = dbus.dbus_message_iter_next(&array);
        }

        var new_status: NetworkStatus = .{
            .kind = .disconnected,
        };

        if (wifi_connected) |device| {
            new_status.kind = .wifi;

            self.fillWifiSsid(
                &new_status,
                device,
            ) catch {
                new_status.ssid_len = 0;
            };
        } else if (ethernet_connected) {
            new_status.kind = .ethernet;
        } else if (wifi_connecting) {
            new_status.kind = .connecting_wifi;
        } else if (ethernet_connecting) {
            new_status.kind = .connecting_ethernet;
        }

        if (!statusEqual(
            &self.status,
            &new_status,
        )) {
            self.status = new_status;
            self.printStatus();
        }
    }

    fn printStatus(self: *const NetworkManager) void {
        switch (self.status.kind) {
            .wifi => std.debug.print(
                "Network: wifi ({s})\n",
                .{self.status.ssidSlice()},
            ),

            else => std.debug.print(
                "Network: {s}\n",
                .{self.status.label()},
            ),
        }
    }

    fn fillWifiSsid(
        self: *NetworkManager,
        status: *NetworkStatus,
        device: [*:0]const u8,
    ) !void {
        const active_ap =
            try self.getObjectPathProperty(
                device,
                "org.freedesktop.NetworkManager.Device.Wireless",
                "ActiveAccessPoint",
            );

        const ap = active_ap orelse {
            status.ssid_len = 0;
            return;
        };

        const reply = try self.getProperty(
            ap,
            "org.freedesktop.NetworkManager.AccessPoint",
            "Ssid",
        );
        defer dbus.dbus_message_unref(reply);

        var iter: dbus.DBusMessageIter = undefined;

        if (dbus.dbus_message_iter_init(
            reply,
            &iter,
        ) == 0) {
            return error.BadReply;
        }

        if (dbus.dbus_message_iter_get_arg_type(
            &iter,
        ) != dbus.DBUS_TYPE_VARIANT) {
            return error.BadReply;
        }

        var variant: dbus.DBusMessageIter = undefined;

        dbus.dbus_message_iter_recurse(
            &iter,
            &variant,
        );

        if (dbus.dbus_message_iter_get_arg_type(
            &variant,
        ) != dbus.DBUS_TYPE_ARRAY) {
            return error.BadReply;
        }

        var bytes: dbus.DBusMessageIter = undefined;

        dbus.dbus_message_iter_recurse(
            &variant,
            &bytes,
        );

        var len: usize = 0;

        while (len < status.ssid.len and
            dbus.dbus_message_iter_get_arg_type(
                &bytes,
            ) != dbus.DBUS_TYPE_INVALID)
        {
            var byte: u8 = 0;

            dbus.dbus_message_iter_get_basic(
                &bytes,
                @as(?*anyopaque, @ptrCast(&byte)),
            );

            status.ssid[len] = byte;
            len += 1;

            _ = dbus.dbus_message_iter_next(&bytes);
        }

        status.ssid_len = len;
    }

    fn getU32Property(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
    ) !u32 {
        const reply = try self.getProperty(
            object,
            interface,
            property,
        );
        defer dbus.dbus_message_unref(reply);

        var iter: dbus.DBusMessageIter = undefined;

        if (dbus.dbus_message_iter_init(
            reply,
            &iter,
        ) == 0) {
            return error.BadReply;
        }

        if (dbus.dbus_message_iter_get_arg_type(
            &iter,
        ) != dbus.DBUS_TYPE_VARIANT) {
            return error.BadReply;
        }

        var variant: dbus.DBusMessageIter = undefined;

        dbus.dbus_message_iter_recurse(
            &iter,
            &variant,
        );

        if (dbus.dbus_message_iter_get_arg_type(
            &variant,
        ) != dbus.DBUS_TYPE_UINT32) {
            return error.BadReply;
        }

        var value: u32 = 0;

        dbus.dbus_message_iter_get_basic(
            &variant,
            @as(?*anyopaque, @ptrCast(&value)),
        );

        return value;
    }

    fn getObjectPathProperty(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
    ) !?[*:0]const u8 {
        const reply = try self.getProperty(
            object,
            interface,
            property,
        );
        defer dbus.dbus_message_unref(reply);

        var iter: dbus.DBusMessageIter = undefined;

        if (dbus.dbus_message_iter_init(
            reply,
            &iter,
        ) == 0) {
            return error.BadReply;
        }

        if (dbus.dbus_message_iter_get_arg_type(
            &iter,
        ) != dbus.DBUS_TYPE_VARIANT) {
            return error.BadReply;
        }

        var variant: dbus.DBusMessageIter = undefined;

        dbus.dbus_message_iter_recurse(
            &iter,
            &variant,
        );

        if (dbus.dbus_message_iter_get_arg_type(
            &variant,
        ) != dbus.DBUS_TYPE_OBJECT_PATH) {
            return error.BadReply;
        }

        var path: [*:0]const u8 = undefined;

        dbus.dbus_message_iter_get_basic(
            &variant,
            @as(?*anyopaque, @ptrCast(&path)),
        );

        return path;
    }

    fn getProperty(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
    ) !*dbus.struct_DBusMessage {
        const msg = dbus.dbus_message_new_method_call(
            "org.freedesktop.NetworkManager",
            object,
            "org.freedesktop.DBus.Properties",
            "Get",
        ) orelse return error.OutOfMemory;

        defer dbus.dbus_message_unref(msg);

        var interface_ptr: [*:0]const u8 = interface;
        var property_ptr: [*:0]const u8 = property;

        if (dbus.dbus_message_append_args(
            msg,
            dbus.DBUS_TYPE_STRING,
            @as(?*anyopaque, @ptrCast(&interface_ptr)),
            dbus.DBUS_TYPE_STRING,
            @as(?*anyopaque, @ptrCast(&property_ptr)),
            dbus.DBUS_TYPE_INVALID,
        ) == 0) {
            return error.OutOfMemory;
        }

        return dbus.dbus_connection_send_with_reply_and_block(
            self.connection,
            msg,
            -1,
            null,
        ) orelse error.DBusCall;
    }

    fn callMethod(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        method: [*:0]const u8,
    ) !*dbus.struct_DBusMessage {
        const msg = dbus.dbus_message_new_method_call(
            "org.freedesktop.NetworkManager",
            object,
            interface,
            method,
        ) orelse return error.OutOfMemory;

        defer dbus.dbus_message_unref(msg);

        return dbus.dbus_connection_send_with_reply_and_block(
            self.connection,
            msg,
            -1,
            null,
        ) orelse error.DBusCall;
    }

    pub fn destroy(self: *NetworkManager) void {
        dbus.dbus_connection_unref(self.connection);

        self.allocator.destroy(self.eventSource);
        self.allocator.destroy(self);
    }
};

fn statusEqual(
    a: *const NetworkStatus,
    b: *const NetworkStatus,
) bool {
    if (a.kind != b.kind) {
        return false;
    }

    if (a.kind == .wifi) {
        return std.mem.eql(
            u8,
            a.ssidSlice(),
            b.ssidSlice(),
        );
    }

    return true;
}
