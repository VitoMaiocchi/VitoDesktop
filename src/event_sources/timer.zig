const std = @import("std");
const linux = std.os.linux;
const EventSource = @import("../types.zig").EventSource;

const time = @cImport({
    @cInclude("time.h");
});

pub const Timer = struct {
    allocator: std.mem.Allocator,
    callback: *const fn (c_long, *anyopaque) void,
    data: *anyopaque,
    eventSource: *const EventSource,

    pub fn create(allocator: std.mem.Allocator, T: type, callback: *const fn (c_long, *T) void, data: *T) !*const Timer {
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

        const eventSource = try allocator.create(EventSource);
        const self = try allocator.create(Timer);

        self.* = .{
            .allocator = allocator,
            .callback = @ptrCast(callback),
            .data = data,
            .eventSource = eventSource,
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
        const self: *Timer = @ptrCast(@alignCast(event.context.?));
        var expirations: u64 = undefined;
        _ = linux.read(
            event.fd,
            std.mem.asBytes(&expirations).ptr,
            @sizeOf(u64),
        );
        const now = time.time(null);
        self.callback(now, self.data);
    }

    pub fn destroy(self: *const Timer) void {
        _ = linux.close(self.eventSource.fd);
        self.allocator.destroy(self.eventSource);
        self.allocator.destroy(self);
    }
};
