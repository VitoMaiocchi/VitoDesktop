const std = @import("std");
const EventSource = @import("../types.zig").EventSource;

const dbus = @cImport({
    @cInclude("dbus/dbus.h");
});

const NM = "org.freedesktop.NetworkManager";
const NM_DEVICE = "org.freedesktop.NetworkManager.Device";
const NM_WIRELESS = "org.freedesktop.NetworkManager.Device.Wireless";
const NM_AP = "org.freedesktop.NetworkManager.AccessPoint";
const NM_IP4_CONFIG = "org.freedesktop.NetworkManager.IP4Config";
const DBUS_PROPS = "org.freedesktop.DBus.Properties";

const MATCH_NM = "type='signal',interface='org.freedesktop.NetworkManager',member='StateChanged'";
const MATCH_DEVICE = "type='signal',interface='org.freedesktop.NetworkManager.Device',member='StateChanged'";
const MATCH_PROPS = "type='signal',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'";

const NM_DEVICE_ETHERNET: u32 = 1;
const NM_DEVICE_WIFI: u32 = 2;
const NM_DEVICE_PREPARE: u32 = 40;
const NM_DEVICE_SECONDARIES: u32 = 90;
const NM_DEVICE_ACTIVATED: u32 = 100;

const PATH_BUF_LEN: usize = 256;

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
    wifi_quality: ?u8 = null,
    ip: [16]u8 = undefined,
    ip_len: usize = 0,

    pub fn ssidSlice(self: *const NetworkStatus) []const u8 {
        return self.ssid[0..self.ssid_len];
    }

    pub fn ipSlice(self: *const NetworkStatus) []const u8 {
        return self.ip[0..self.ip_len];
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

fn copyPath(dest: *[PATH_BUF_LEN]u8, src: [*:0]const u8) ?[*:0]const u8 {
    const span = std.mem.span(src);
    if (span.len == 0 or span.len >= dest.len) return null;
    @memcpy(dest[0..span.len], span);
    dest[span.len] = 0;
    const p: [*:0]u8 = @ptrCast(dest);
    return p;
}

pub const NetworkManager = struct {
    allocator: std.mem.Allocator,
    eventSource: *EventSource,
    connection: *dbus.struct_DBusConnection,
    status: NetworkStatus,

    pub fn create(allocator: std.mem.Allocator) !*NetworkManager {
        const connection = dbus.dbus_bus_get(dbus.DBUS_BUS_SYSTEM, null) orelse
            return error.DBusConnect;
        errdefer dbus.dbus_connection_unref(connection);

        const self = try allocator.create(NetworkManager);
        errdefer allocator.destroy(self);

        const eventSource = try allocator.create(EventSource);
        errdefer allocator.destroy(eventSource);

        self.* = .{
            .allocator = allocator,
            .eventSource = eventSource,
            .connection = connection,
            .status = .{ .kind = .disconnected },
        };

        dbus.dbus_bus_add_match(connection, MATCH_NM, null);
        dbus.dbus_bus_add_match(connection, MATCH_DEVICE, null);
        dbus.dbus_bus_add_match(connection, MATCH_PROPS, null);
        dbus.dbus_connection_flush(connection);

        var fd: c_int = -1;
        if (dbus.dbus_connection_get_unix_fd(connection, &fd) == 0)
            return error.NoFd;

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
        const self: *NetworkManager = @ptrCast(@alignCast(event.context.?));

        _ = dbus.dbus_connection_read_write(self.connection, 0);

        while (dbus.dbus_connection_pop_message(self.connection)) |msg| {
            defer dbus.dbus_message_unref(msg);

            if (dbus.dbus_message_is_signal(msg, NM, "StateChanged") != 0 or
                dbus.dbus_message_is_signal(msg, NM_DEVICE, "StateChanged") != 0 or
                dbus.dbus_message_is_signal(msg, DBUS_PROPS, "PropertiesChanged") != 0)
            {
                self.refresh() catch |err| {
                    std.log.err("NetworkManager refresh failed: {}", .{err});
                };
            }
        }
    }

    fn refresh(self: *NetworkManager) !void {
        const reply = try self.callMethod("/org/freedesktop/NetworkManager", NM, "GetDevices");
        defer dbus.dbus_message_unref(reply);

        var iter: dbus.DBusMessageIter = undefined;
        if (dbus.dbus_message_iter_init(reply, &iter) == 0 or
            dbus.dbus_message_iter_get_arg_type(&iter) != dbus.DBUS_TYPE_ARRAY)
            return error.BadReply;

        var array: dbus.DBusMessageIter = undefined;
        dbus.dbus_message_iter_recurse(&iter, &array);

        var wifi_device_buf: [PATH_BUF_LEN]u8 = undefined;
        var wifi_device: ?[*:0]const u8 = null;
        var ethernet_device_buf: [PATH_BUF_LEN]u8 = undefined;
        var ethernet_device: ?[*:0]const u8 = null;
        var wifi_connecting = false;
        var ethernet_connecting = false;

        while (dbus.dbus_message_iter_get_arg_type(&array) != dbus.DBUS_TYPE_INVALID) {
            var device_path: [*:0]const u8 = undefined;
            dbus.dbus_message_iter_get_basic(&array, @ptrCast(&device_path));

            const device_type = self.getU32Property(device_path, NM_DEVICE, "DeviceType") catch {
                _ = dbus.dbus_message_iter_next(&array);
                continue;
            };

            const state = self.getU32Property(device_path, NM_DEVICE, "State") catch {
                _ = dbus.dbus_message_iter_next(&array);
                continue;
            };

            const connecting = state >= NM_DEVICE_PREPARE and state <= NM_DEVICE_SECONDARIES;

            switch (device_type) {
                NM_DEVICE_WIFI => {
                    if (state == NM_DEVICE_ACTIVATED) {
                        if (copyPath(&wifi_device_buf, device_path)) |p| wifi_device = p;
                    } else if (connecting) {
                        wifi_connecting = true;
                    }
                },
                NM_DEVICE_ETHERNET => {
                    if (state == NM_DEVICE_ACTIVATED) {
                        if (copyPath(&ethernet_device_buf, device_path)) |p| ethernet_device = p;
                    } else if (connecting) {
                        ethernet_connecting = true;
                    }
                },
                else => {},
            }

            _ = dbus.dbus_message_iter_next(&array);
        }

        var new_status: NetworkStatus = .{ .kind = .disconnected };

        if (wifi_device) |device| {
            new_status.kind = .wifi;
            self.fillWifiInfo(&new_status, device) catch {
                new_status.ssid_len = 0;
                new_status.wifi_quality = null;
            };
            self.fillIp(&new_status, device) catch {
                new_status.ip_len = 0;
            };
        } else if (ethernet_device) |device| {
            new_status.kind = .ethernet;
            self.fillIp(&new_status, device) catch {
                new_status.ip_len = 0;
            };
        } else if (wifi_connecting) {
            new_status.kind = .connecting_wifi;
        } else if (ethernet_connecting) {
            new_status.kind = .connecting_ethernet;
        }

        if (!statusEqual(&self.status, &new_status)) {
            self.status = new_status;
            self.printStatus();
        }
    }

    fn printStatus(self: *const NetworkManager) void {
        switch (self.status.kind) {
            .wifi => {
                const ssid = self.status.ssidSlice();
                const ip = self.status.ipSlice();
                if (self.status.wifi_quality) |q| {
                    std.debug.print("Network: wifi ({s}, {d}%) ip={s}\n", .{ ssid, q, ip });
                } else {
                    std.debug.print("Network: wifi ({s}) ip={s}\n", .{ ssid, ip });
                }
            },
            .ethernet => std.debug.print("Network: ethernet ip={s}\n", .{self.status.ipSlice()}),
            else => std.debug.print("Network: {s}\n", .{self.status.label()}),
        }
    }

    fn fillWifiInfo(
        self: *NetworkManager,
        status: *NetworkStatus,
        device: [*:0]const u8,
    ) !void {
        status.ssid_len = 0;
        status.wifi_quality = null;

        const ap_opt = try self.getObjectPathProperty(device, NM_WIRELESS, "ActiveAccessPoint");
        const ap_raw = ap_opt orelse return;

        var ap_buf: [PATH_BUF_LEN]u8 = undefined;
        const ap = copyPath(&ap_buf, ap_raw) orelse return;

        const reply = try self.getProperty(ap, NM_AP, "Ssid");
        defer dbus.dbus_message_unref(reply);

        var variant: dbus.DBusMessageIter = undefined;
        try getVariant(reply, &variant);

        if (dbus.dbus_message_iter_get_arg_type(&variant) != dbus.DBUS_TYPE_ARRAY)
            return error.BadReply;

        var bytes: dbus.DBusMessageIter = undefined;
        dbus.dbus_message_iter_recurse(&variant, &bytes);

        var len: usize = 0;
        while (len < status.ssid.len and
            dbus.dbus_message_iter_get_arg_type(&bytes) != dbus.DBUS_TYPE_INVALID)
        {
            var byte: u8 = 0;
            dbus.dbus_message_iter_get_basic(&bytes, @ptrCast(&byte));
            status.ssid[len] = byte;
            len += 1;
            _ = dbus.dbus_message_iter_next(&bytes);
        }

        status.ssid_len = len;
        status.wifi_quality = self.getU8Property(ap, NM_AP, "Strength") catch null;
    }

    fn fillIp(self: *NetworkManager, status: *NetworkStatus, device: [*:0]const u8) !void {
        status.ip_len = 0;

        const config_opt = try self.getObjectPathProperty(device, NM_DEVICE, "Ip4Config");
        const config_raw = config_opt orelse return;

        var config_buf: [PATH_BUF_LEN]u8 = undefined;
        const config = copyPath(&config_buf, config_raw) orelse return;

        const reply = try self.getProperty(config, NM_IP4_CONFIG, "Addresses");
        defer dbus.dbus_message_unref(reply);

        var variant: dbus.DBusMessageIter = undefined;
        try getVariant(reply, &variant);

        if (dbus.dbus_message_iter_get_arg_type(&variant) != dbus.DBUS_TYPE_ARRAY)
            return error.BadReply;

        var outer: dbus.DBusMessageIter = undefined;
        dbus.dbus_message_iter_recurse(&variant, &outer);

        while (dbus.dbus_message_iter_get_arg_type(&outer) != dbus.DBUS_TYPE_INVALID) {
            if (dbus.dbus_message_iter_get_arg_type(&outer) != dbus.DBUS_TYPE_ARRAY) {
                _ = dbus.dbus_message_iter_next(&outer);
                continue;
            }

            var inner: dbus.DBusMessageIter = undefined;
            dbus.dbus_message_iter_recurse(&outer, &inner);

            if (dbus.dbus_message_iter_get_arg_type(&inner) == dbus.DBUS_TYPE_UINT32) {
                var addr: u32 = 0;
                dbus.dbus_message_iter_get_basic(&inner, @ptrCast(&addr));
                const octets: [4]u8 = @bitCast(addr);
                const s = std.fmt.bufPrint(
                    status.ip[0..],
                    "{d}.{d}.{d}.{d}",
                    .{ octets[0], octets[1], octets[2], octets[3] },
                ) catch return error.BadReply;
                status.ip_len = s.len;
                return;
            }

            _ = dbus.dbus_message_iter_next(&outer);
        }
    }

    fn getU8Property(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
    ) !u8 {
        const reply = try self.getProperty(object, interface, property);
        defer dbus.dbus_message_unref(reply);

        var variant: dbus.DBusMessageIter = undefined;
        try getVariant(reply, &variant);

        if (dbus.dbus_message_iter_get_arg_type(&variant) != dbus.DBUS_TYPE_BYTE)
            return error.BadReply;

        var value: u8 = 0;
        dbus.dbus_message_iter_get_basic(&variant, @ptrCast(&value));
        return value;
    }

    fn getU32Property(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
    ) !u32 {
        const reply = try self.getProperty(object, interface, property);
        defer dbus.dbus_message_unref(reply);

        var variant: dbus.DBusMessageIter = undefined;
        try getVariant(reply, &variant);

        if (dbus.dbus_message_iter_get_arg_type(&variant) != dbus.DBUS_TYPE_UINT32)
            return error.BadReply;

        var value: u32 = 0;
        dbus.dbus_message_iter_get_basic(&variant, @ptrCast(&value));
        return value;
    }

    fn getObjectPathProperty(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
    ) !?[*:0]const u8 {
        const reply = try self.getProperty(object, interface, property);
        defer dbus.dbus_message_unref(reply);

        var variant: dbus.DBusMessageIter = undefined;
        try getVariant(reply, &variant);

        if (dbus.dbus_message_iter_get_arg_type(&variant) != dbus.DBUS_TYPE_OBJECT_PATH)
            return error.BadReply;

        var path: [*:0]const u8 = undefined;
        dbus.dbus_message_iter_get_basic(&variant, @ptrCast(&path));
        return path;
    }

    fn getProperty(
        self: *NetworkManager,
        object: [*:0]const u8,
        interface: [*:0]const u8,
        property: [*:0]const u8,
    ) !*dbus.struct_DBusMessage {
        const msg = dbus.dbus_message_new_method_call(NM, object, DBUS_PROPS, "Get") orelse
            return error.OutOfMemory;
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
        ) == 0) return error.OutOfMemory;

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
        const msg = dbus.dbus_message_new_method_call(NM, object, interface, method) orelse
            return error.OutOfMemory;
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

fn getVariant(reply: *dbus.struct_DBusMessage, out: *dbus.DBusMessageIter) !void {
    var iter: dbus.DBusMessageIter = undefined;

    if (dbus.dbus_message_iter_init(reply, &iter) == 0 or
        dbus.dbus_message_iter_get_arg_type(&iter) != dbus.DBUS_TYPE_VARIANT)
        return error.BadReply;

    dbus.dbus_message_iter_recurse(&iter, out);
}

fn statusEqual(a: *const NetworkStatus, b: *const NetworkStatus) bool {
    if (a.kind != b.kind) return false;
    if (a.kind == .wifi) {
        if (!std.mem.eql(u8, a.ssidSlice(), b.ssidSlice())) return false;
        if (a.wifi_quality != b.wifi_quality) return false;
    }
    if (!std.mem.eql(u8, a.ipSlice(), b.ipSlice())) return false;
    return true;
}
