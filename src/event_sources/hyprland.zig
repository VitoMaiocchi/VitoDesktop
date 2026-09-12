const std = @import("std");
const linux = std.os.linux;

const EventSource = @import("../types.zig").EventSource;

fn dispatchHyprlandEvent(event: *const EventSource) anyerror!void {
    var buffer: [4096]u8 = undefined;
    const n = linux.read(event.fd, &buffer, buffer.len);

    if (n > 0) {
        std.debug.print("{s}", .{buffer[0..n]});
    }
}

pub fn init(process_init: std.process.Init) !EventSource { //print current workspace
    const xdg = process_init.environ_map.get("XDG_RUNTIME_DIR").?;
    const his = process_init.environ_map.get("HYPRLAND_INSTANCE_SIGNATURE").?;

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
