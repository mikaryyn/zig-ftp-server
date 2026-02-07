const std = @import("std");
const interfaces_net = @import("interfaces_net.zig");

/// Event emitted by the control-line reader.
pub const ReadEvent = union(enum) {
    /// No complete event is currently available.
    none,
    /// A full CRLF-terminated line without trailing CRLF.
    line: []const u8,
    /// A too-long line was fully discarded through its terminating CRLF.
    too_long,
};

/// Non-blocking CRLF line reader over `Net.read`.
pub fn LineReader(comptime Net: type) type {
    return struct {
        const Self = @This();

        /// Caller-owned staging buffer for control-channel bytes.
        buffer: []u8,
        /// Number of bytes currently staged in `buffer`.
        len: usize = 0,
        /// Number of staged bytes to discard at start of next poll.
        pending_consume: usize = 0,
        /// Whether we are currently discarding an overlong line.
        discarding_long_line: bool = false,

        /// Initialize a line reader with caller-provided storage.
        pub fn init(buffer: []u8) Self {
            return .{ .buffer = buffer };
        }

        /// Poll for one line event. Returned `.line` slices stay valid until next `poll` call.
        pub fn poll(self: *Self, net: *Net, conn: *Net.Conn) interfaces_net.NetError!ReadEvent {
            self.applyPendingConsume();

            if (self.processBuffered()) |event| {
                return event;
            }

            if (self.len == self.buffer.len) {
                self.makeDiscardRoom();
                if (self.processBuffered()) |event| {
                    return event;
                }
            }

            const room = self.buffer[self.len..];
            if (room.len == 0) {
                return .none;
            }

            const n = net.read(conn, room) catch |err| switch (err) {
                error.WouldBlock => return .none,
                else => return err,
            };
            if (n == 0) return error.Closed;

            self.len += n;
            return self.processBuffered() orelse .none;
        }

        fn processBuffered(self: *Self) ?ReadEvent {
            if (self.discarding_long_line) {
                if (findCrlf(self.buffer[0..self.len])) |idx| {
                    self.discardPrefix(idx + 2);
                    self.discarding_long_line = false;
                    return .too_long;
                }
                if (self.len == self.buffer.len) {
                    self.makeDiscardRoom();
                }
                return null;
            }

            if (findCrlf(self.buffer[0..self.len])) |idx| {
                self.pending_consume = idx + 2;
                return .{ .line = self.buffer[0..idx] };
            }

            if (self.len == self.buffer.len) {
                self.discarding_long_line = true;
                self.makeDiscardRoom();
            }

            return null;
        }

        fn applyPendingConsume(self: *Self) void {
            if (self.pending_consume == 0) return;
            self.discardPrefix(self.pending_consume);
            self.pending_consume = 0;
        }

        fn discardPrefix(self: *Self, prefix_len: usize) void {
            if (prefix_len >= self.len) {
                self.len = 0;
                return;
            }

            const remaining = self.len - prefix_len;
            std.mem.copyForwards(u8, self.buffer[0..remaining], self.buffer[prefix_len..self.len]);
            self.len = remaining;
        }

        fn makeDiscardRoom(self: *Self) void {
            if (self.len == 0) return;

            if (self.buffer[self.len - 1] == '\r') {
                self.buffer[0] = '\r';
                self.len = 1;
            } else {
                self.len = 0;
            }
        }
    };
}

fn findCrlf(bytes: []const u8) ?usize {
    if (bytes.len < 2) return null;

    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        if (bytes[i] == '\r' and bytes[i + 1] == '\n') {
            return i;
        }
    }
    return null;
}

const mock_net = @import("mock_net.zig");
const testing = std.testing;

test "line reader handles CRLF split across reads" {
    var net: mock_net.MockNet = .{
        .read_script = &.{
            .{ .bytes = "USER test\r" },
            .{ .bytes = "\n" },
        },
    };
    var conn: mock_net.MockNet.Conn = .{};

    var buf: [32]u8 = undefined;
    var reader = LineReader(mock_net.MockNet).init(buf[0..]);

    try testing.expectEqual(ReadEvent.none, try reader.poll(&net, &conn));

    const event = try reader.poll(&net, &conn);
    switch (event) {
        .line => |line| try testing.expect(std.mem.eql(u8, "USER test", line)),
        else => return error.UnexpectedTestResult,
    }
}

test "line reader returns buffered second line without a new read" {
    var net: mock_net.MockNet = .{
        .read_script = &.{
            .{ .bytes = "NOOP\r\nQUIT\r\n" },
        },
    };
    var conn: mock_net.MockNet.Conn = .{};

    var buf: [32]u8 = undefined;
    var reader = LineReader(mock_net.MockNet).init(buf[0..]);

    const first = try reader.poll(&net, &conn);
    switch (first) {
        .line => |line| try testing.expect(std.mem.eql(u8, "NOOP", line)),
        else => return error.UnexpectedTestResult,
    }

    const second = try reader.poll(&net, &conn);
    switch (second) {
        .line => |line| try testing.expect(std.mem.eql(u8, "QUIT", line)),
        else => return error.UnexpectedTestResult,
    }
}

test "line reader supports empty command lines" {
    var net: mock_net.MockNet = .{
        .read_script = &.{
            .{ .bytes = "\r\n" },
        },
    };
    var conn: mock_net.MockNet.Conn = .{};

    var buf: [16]u8 = undefined;
    var reader = LineReader(mock_net.MockNet).init(buf[0..]);

    const event = try reader.poll(&net, &conn);
    switch (event) {
        .line => |line| try testing.expectEqual(@as(usize, 0), line.len),
        else => return error.UnexpectedTestResult,
    }
}

test "line reader discards overlong line until CRLF and resumes" {
    var net: mock_net.MockNet = .{
        .read_script = &.{
            .{ .bytes = "ABCDEFGH" },
            .{ .bytes = "IJK\r\n" },
            .{ .bytes = "NOOP\r\n" },
        },
    };
    var conn: mock_net.MockNet.Conn = .{};

    var buf: [8]u8 = undefined;
    var reader = LineReader(mock_net.MockNet).init(buf[0..]);

    try testing.expectEqual(ReadEvent.none, try reader.poll(&net, &conn));
    try testing.expectEqual(ReadEvent.too_long, try reader.poll(&net, &conn));

    const next = try reader.poll(&net, &conn);
    switch (next) {
        .line => |line| try testing.expect(std.mem.eql(u8, "NOOP", line)),
        else => return error.UnexpectedTestResult,
    }
}

test "line reader returns none on would-block" {
    var net: mock_net.MockNet = .{
        .read_script = &.{.would_block},
    };
    var conn: mock_net.MockNet.Conn = .{};

    var buf: [16]u8 = undefined;
    var reader = LineReader(mock_net.MockNet).init(buf[0..]);

    try testing.expectEqual(ReadEvent.none, try reader.poll(&net, &conn));
}
