const std = @import("std");
const builtin = @import("builtin");
const net = std.Io.net;
const ftp = @import("ftp_server");
const interfaces_net = ftp.interfaces_net;

/// std.Io.net-based Net implementation for the CLI harness.
pub const NetStd = struct {
    pub const Address = net.IpAddress;

    io: std.Io,

    pub const ControlListener = struct {
        server: net.Server,
    };

    pub const PasvListener = struct {
        server: net.Server,
    };

    pub const Conn = struct {
        stream: net.Stream,
    };

    pub fn controlListen(self: *NetStd, address: Address) interfaces_net.NetError!ControlListener {
        const server = address.listen(self.io, .{
            .reuse_address = true,
        }) catch |err| return mapNetError(err);
        return .{ .server = server };
    }

    pub fn acceptControl(self: *NetStd, listener: *ControlListener) interfaces_net.NetError!?Conn {
        if (!try isReadable(listener.server.socket.handle)) return null;
        const conn = listener.server.accept(self.io) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return mapNetError(err),
        };
        return .{ .stream = conn };
    }

    pub fn pasvListen(_: *NetStd, _: interfaces_net.PasvBindHint(Address)) interfaces_net.NetError!PasvListener {
        return error.Io;
    }

    pub fn pasvLocalAddr(_: *NetStd, _: *PasvListener) interfaces_net.NetError!Address {
        return error.AddrUnavailable;
    }

    pub fn acceptData(self: *NetStd, listener: *PasvListener) interfaces_net.NetError!?Conn {
        if (!try isReadable(listener.server.socket.handle)) return null;
        const conn = listener.server.accept(self.io) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return mapNetError(err),
        };
        return .{ .stream = conn };
    }

    pub fn read(self: *NetStd, conn: *Conn, out: []u8) interfaces_net.NetError!usize {
        if (!try isReadable(conn.stream.socket.handle)) return error.WouldBlock;
        var bufs = [_][]u8{out};
        const n = self.io.vtable.netRead(self.io.userdata, conn.stream.socket.handle, bufs[0..]) catch |err| {
            return mapNetError(err);
        };
        logTraffic("recv", out[0..n]);
        return n;
    }

    pub fn write(self: *NetStd, conn: *Conn, data: []const u8) interfaces_net.NetError!usize {
        if (!try isWritable(conn.stream.socket.handle)) return error.WouldBlock;
        const n = self.io.vtable.netWrite(self.io.userdata, conn.stream.socket.handle, &.{}, &.{data}, 1) catch |err| {
            return mapNetError(err);
        };
        logTraffic("send", data[0..n]);
        return n;
    }

    pub fn closeConn(self: *NetStd, conn: *Conn) void {
        conn.stream.close(self.io);
    }

    pub fn closeListener(self: *NetStd, listener: *PasvListener) void {
        listener.server.deinit(self.io);
    }

    pub fn closeControlListener(self: *NetStd, listener: *ControlListener) void {
        listener.server.deinit(self.io);
    }
};

fn mapNetError(err: anyerror) interfaces_net.NetError {
    return switch (err) {
        error.WouldBlock => error.WouldBlock,
        error.ConnectionResetByPeer,
        error.BrokenPipe,
        => error.Closed,
        error.ConnectionTimedOut => error.Timeout,
        error.AddressNotAvailable => error.AddrUnavailable,
        else => error.Io,
    };
}

fn isReadable(handle: net.Socket.Handle) interfaces_net.NetError!bool {
    return pollReady(handle, std.posix.POLL.IN);
}

fn isWritable(handle: net.Socket.Handle) interfaces_net.NetError!bool {
    return pollReady(handle, std.posix.POLL.OUT);
}

fn pollReady(handle: net.Socket.Handle, events: i16) interfaces_net.NetError!bool {
    if (builtin.os.tag == .windows) return true;

    var poll_fd = std.posix.pollfd{
        .fd = handle,
        .events = events,
        .revents = 0,
    };
    const n = std.posix.poll((&poll_fd)[0..1], 0) catch return error.Io;
    if (n == 0) return false;
    return poll_fd.revents & events == events;
}

fn logTraffic(direction: []const u8, payload: []const u8) void {
    var escaped_buf: [512]u8 = undefined;
    const escaped = escapePayload(payload, escaped_buf[0..]);
    std.log.info("socket {s} {d} bytes: \"{s}\"", .{ direction, payload.len, escaped });
}

fn escapePayload(payload: []const u8, out: []u8) []const u8 {
    var j: usize = 0;
    var truncated = false;

    for (payload) |b| {
        const replacement: ?[]const u8 = switch (b) {
            '\r' => "\\r",
            '\n' => "\\n",
            '\t' => "\\t",
            '\\' => "\\\\",
            '"' => "\\\"",
            else => null,
        };

        if (replacement) |r| {
            if (j + r.len > out.len) {
                truncated = true;
                break;
            }
            std.mem.copyForwards(u8, out[j .. j + r.len], r);
            j += r.len;
            continue;
        }

        if (b >= 0x20 and b <= 0x7e) {
            if (j + 1 > out.len) {
                truncated = true;
                break;
            }
            out[j] = b;
            j += 1;
            continue;
        }

        if (j + 4 > out.len) {
            truncated = true;
            break;
        }
        out[j] = '\\';
        out[j + 1] = 'x';
        out[j + 2] = hexNibble((b >> 4) & 0x0f);
        out[j + 3] = hexNibble(b & 0x0f);
        j += 4;
    }

    if (truncated and j + 3 <= out.len) {
        out[j] = '.';
        out[j + 1] = '.';
        out[j + 2] = '.';
        j += 3;
    }

    return out[0..j];
}

fn hexNibble(n: u8) u8 {
    return if (n < 10) ('0' + n) else ('a' + (n - 10));
}
