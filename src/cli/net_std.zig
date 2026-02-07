const std = @import("std");
const net = std.Io.net;

/// std.Io.net-based Net implementation for the CLI harness.
pub const NetStd = struct {
    /// Address type used by std.Io.net.
    pub const Address = net.IpAddress;

    /// Io implementation used for network operations.
    io: std.Io,

    /// Wrapper around a std.net.Server control listener.
    pub const ControlListener = struct {
        /// Underlying std.Io.net server listener.
        server: net.Server,
    };

    /// Wrapper around a std.net.Stream connection.
    pub const Conn = struct {
        /// Underlying std.Io.net stream.
        stream: net.Stream,
    };

    /// Open a non-blocking control listener.
    pub fn controlListen(self: *NetStd, address: Address) !ControlListener {
        const server = try address.listen(self.io, .{
            .reuse_address = true,
        });
        return .{ .server = server };
    }

    /// Accept a control connection or return null on WouldBlock.
    pub fn acceptControl(self: *NetStd, listener: *ControlListener) !?Conn {
        const conn = listener.server.accept(self.io) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        return .{ .stream = conn };
    }

    /// Write data to a control connection.
    pub fn write(self: *NetStd, conn: *const Conn, data: []const u8) !usize {
        return self.io.vtable.netWrite(self.io.userdata, conn.stream.socket.handle, &.{}, &.{data}, 1);
    }

    /// Close a control connection.
    pub fn closeConn(self: *NetStd, conn: *const Conn) void {
        conn.stream.close(self.io);
    }

    /// Close the control listener.
    pub fn closeListener(self: *NetStd, listener: *ControlListener) void {
        listener.server.deinit(self.io);
    }
};
