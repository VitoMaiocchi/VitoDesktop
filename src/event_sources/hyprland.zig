const std = @import("std");
const linux = std.os.linux;

const EventSource = @import("../types.zig").EventSource;

pub const Hyprland = struct {
    eventSource: *const EventSource,
    allocator: std.mem.Allocator,

    activeWindow: *const fn ([]const u8, *anyopaque) void,
    data: *anyopaque,

    const EventType = enum {
        workspacev2,
        focusedmonv2,
        activewindow,
    };

    const event_map = std.StaticStringMap(EventType).initComptime(.{
        .{ "workspacev2", .workspacev2 },
        .{ "focusedmonv2", .focusedmonv2 },
        .{ "activewindow", .activewindow },
    });

    fn handleEvent(self: *Hyprland, name: []const u8, data: []const u8) void {
        //std.debug.print("hyprland event {s} data={s}\n", .{ name, data });
        const kind = event_map.get(name) orelse return;
        switch (kind) {
            .workspacev2 => {},
            .focusedmonv2 => {},
            .activewindow => {
                const comma = std.mem.indexOfScalar(u8, data, ',') orelse return;
                const result = data[comma + 1 ..];
                self.activeWindow(result, self.data);
            },
        }
    }

    fn dispatch(event: *const EventSource) anyerror!void {
        const self: *Hyprland = @ptrCast(@alignCast(event.context));
        var buffer: [4096]u8 = undefined;
        const n = linux.read(event.fd, &buffer, buffer.len);
        if (n <= 0) return;

        var lines = std.mem.splitScalar(u8, buffer[0..@intCast(n)], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const sep = std.mem.indexOf(u8, line, ">>") orelse continue;
            handleEvent(self, line[0..sep], line[sep + 2 ..]);
        }
    }

    fn getIPC(command: []const u8, addr: *linux.sockaddr.un, rbuffer: []u8, len: usize) []u8 {
        const hyprSockFd: i32 = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0));
        defer _ = linux.close(hyprSockFd);

        _ = linux.connect(hyprSockFd, @ptrCast(addr), @sizeOf(linux.sockaddr.un));
        _ = linux.write(hyprSockFd, command.ptr, command.len);
        const n = linux.read(hyprSockFd, rbuffer.ptr, len);
        return rbuffer[0..n];
    }

    fn getActive(self: *Hyprland, addr: *linux.sockaddr.un) !void {
        var rbuffer: [1024]u8 = undefined;
        const json = getIPC("j/activeworkspace", addr, &rbuffer, rbuffer.len);

        const parsed = try std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            json,
            .{},
        );
        defer parsed.deinit();

        const title = parsed.value.object.get("lastwindowtitle").?.string;

        self.activeWindow(title, self.data);
    }

    pub fn create(
        allocator: std.mem.Allocator,
        process_init: std.process.Init,
        T: type,
        activeWindow: *const fn ([]const u8, *T) void,
        data: *T,
    ) !*const Hyprland { //print current workspace
        const xdg = process_init.environ_map.get("XDG_RUNTIME_DIR").?;
        const his = process_init.environ_map.get("HYPRLAND_INSTANCE_SIGNATURE").?;

        var addr2: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        const path2 = try std.fmt.bufPrint(&addr2.path, "{s}/hypr/{s}/.socket2.sock", .{ xdg, his });
        addr2.path[path2.len] = 0;

        const fd: i32 = @intCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0));

        _ = linux.connect(fd, @ptrCast(&addr2), @sizeOf(linux.sockaddr.un));

        const eventSource = try allocator.create(EventSource);
        const self = try allocator.create(Hyprland);

        self.* = .{ .eventSource = eventSource, .allocator = allocator, .activeWindow = @ptrCast(activeWindow), .data = data };

        eventSource.* = .{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .dispatchFn = dispatch,
            .context = self,
        };

        //fetch initial data
        var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
        const path = try std.fmt.bufPrint(&addr.path, "{s}/hypr/{s}/.socket.sock", .{ xdg, his });
        addr.path[path.len] = 0;
        try getActive(self, &addr);

        return self;
    }

    pub fn destroy(self: *const Hyprland) void {
        _ = linux.close(self.eventSource.fd);
        self.allocator.destroy(self.eventSource);
        self.allocator.destroy(self);
    }
};
