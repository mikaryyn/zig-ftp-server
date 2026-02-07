const std = @import("std");
const interfaces_net = @import("interfaces_net.zig");

/// Formatting errors when staging control replies.
pub const QueueError = error{
    Busy,
    BufferTooSmall,
};

/// Non-blocking reply formatter and resumable writer.
pub fn ReplyWriter(comptime Net: type) type {
    return struct {
        const Self = @This();

        /// Caller-owned buffer that holds the currently staged reply payload.
        buffer: []u8,
        /// Number of valid bytes in `buffer`.
        len: usize = 0,
        /// Current write offset into the staged payload.
        offset: usize = 0,

        /// Initialize with caller-provided buffer.
        pub fn init(buffer: []u8) Self {
            return .{ .buffer = buffer };
        }

        /// Whether there are bytes still pending for network write.
        pub fn isPending(self: *const Self) bool {
            return self.offset < self.len;
        }

        /// Stage a single-line FTP reply (`<code> <text>\r\n`).
        pub fn queueLine(self: *Self, code: u16, text: []const u8) QueueError!void {
            if (self.isPending()) return error.Busy;

            self.len = 0;
            self.offset = 0;

            try self.appendCode(code);
            try self.append(" ");
            try self.append(text);
            try self.append("\r\n");
        }

        /// Stage a multiline FEAT reply.
        pub fn queueFeat(self: *Self, features: []const []const u8) QueueError!void {
            if (self.isPending()) return error.Busy;

            self.len = 0;
            self.offset = 0;

            try self.append("211-Features:\r\n");
            for (features) |feature| {
                try self.append(" ");
                try self.append(feature);
                try self.append("\r\n");
            }
            try self.append("211 End\r\n");
        }

        /// Attempt to flush all pending bytes. Returns false on WouldBlock.
        pub fn flush(self: *Self, net: *Net, conn: *Net.Conn) interfaces_net.NetError!bool {
            while (self.offset < self.len) {
                const wrote = net.write(conn, self.buffer[self.offset..self.len]) catch |err| switch (err) {
                    error.WouldBlock => return false,
                    else => return err,
                };
                if (wrote == 0) return error.Closed;
                self.offset += wrote;
            }

            self.clear();
            return true;
        }

        fn appendCode(self: *Self, code: u16) QueueError!void {
            var code_buf: [8]u8 = undefined;
            const text = std.fmt.bufPrint(code_buf[0..], "{d}", .{code}) catch return error.BufferTooSmall;
            try self.append(text);
        }

        fn append(self: *Self, text: []const u8) QueueError!void {
            const available = self.buffer.len - self.len;
            if (text.len > available) return error.BufferTooSmall;

            std.mem.copyForwards(u8, self.buffer[self.len .. self.len + text.len], text);
            self.len += text.len;
        }

        fn clear(self: *Self) void {
            self.len = 0;
            self.offset = 0;
        }
    };
}

const mock_net = @import("mock_net.zig");
const testing = std.testing;

test "queueLine formats single-line reply" {
    var storage: [64]u8 = undefined;
    var writer = ReplyWriter(mock_net.MockNet).init(storage[0..]);

    try writer.queueLine(220, "FTP Server Ready");
    try testing.expect(std.mem.eql(u8, "220 FTP Server Ready\r\n", storage[0..writer.len]));
}

test "queueFeat formats multiline FEAT reply" {
    var storage: [96]u8 = undefined;
    var writer = ReplyWriter(mock_net.MockNet).init(storage[0..]);

    const features = [_][]const u8{ "PASV", "TYPE I" };
    try writer.queueFeat(features[0..]);

    const expected =
        "211-Features:\r\n" ++
        " PASV\r\n" ++
        " TYPE I\r\n" ++
        "211 End\r\n";
    try testing.expect(std.mem.eql(u8, expected, storage[0..writer.len]));
}

test "flush handles partial writes and would-block" {
    var net: mock_net.MockNet = .{
        .write_script = &.{
            .{ .accept = 4 },
            .would_block,
            .{ .accept = 64 },
        },
    };
    var conn: mock_net.MockNet.Conn = .{};

    var storage: [64]u8 = undefined;
    var writer = ReplyWriter(mock_net.MockNet).init(storage[0..]);
    try writer.queueLine(221, "Bye");

    try testing.expectEqual(false, try writer.flush(&net, &conn));
    try testing.expect(std.mem.eql(u8, "221 ", net.written()));

    try testing.expectEqual(false, try writer.flush(&net, &conn));
    try testing.expect(std.mem.eql(u8, "221 ", net.written()));

    try testing.expectEqual(true, try writer.flush(&net, &conn));
    try testing.expect(std.mem.eql(u8, "221 Bye\r\n", net.written()));
    try testing.expect(!writer.isPending());
}

test "queue refuses overwrite while data is pending" {
    var storage: [64]u8 = undefined;
    var writer = ReplyWriter(mock_net.MockNet).init(storage[0..]);

    try writer.queueLine(220, "ready");
    try testing.expectError(error.Busy, writer.queueLine(221, "bye"));
}
