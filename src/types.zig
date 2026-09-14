const std = @import("std");

pub const Format = enum {
    ARGB8888,
};

pub const EventSource = struct {
    fd: std.posix.fd_t,
    events: i16,

    dispatchFn: *const fn (event: *const EventSource) anyerror!void,
    context: ?*anyopaque,

    pub fn dispatch(self: *const EventSource) anyerror!void {
        return self.dispatchFn(self);
    }
};

pub const DrawableSurface = struct {
    data: [*c]u8,
    format: Format,
    width: c_int,
    height: c_int,
    stride: c_int,
    scale: u32,
};
