const std = @import("std");
const interfaces_net = @import("interfaces_net.zig");

/// Deterministic scripted Net mock used by protocol unit tests.
pub const MockNet = struct {
    /// Scripted control-accept behavior consumed one entry per `acceptControl` call.
    control_accept_script: []const AcceptOp = &.{},
    control_accept_index: usize = 0,

    /// Scripted read behavior consumed one entry per `read` call.
    read_script: []const ReadOp = &.{},
    read_index: usize = 0,

    /// Scripted write behavior consumed one entry per `write` call.
    write_script: []const WriteOp = &.{},
    write_index: usize = 0,

    /// Captured data accepted by `write`.
    write_capture: [8192]u8 = undefined,
    write_capture_len: usize = 0,

    /// Captured control/data connection ids passed to `closeConn`.
    closed_conn_ids: [64]u16 = undefined,
    closed_conn_len: usize = 0,

    /// Address type used by the mock.
    pub const Address = struct {
        ip: [4]u8 = .{ 127, 0, 0, 1 },
        port: u16 = 2121,
    };

    /// Placeholder listener type for control connections.
    pub const ControlListener = struct {
        owner: *MockNet,
    };
    /// Placeholder data listener type for PASV.
    pub const PasvListener = struct {
        owner: *MockNet,
    };
    /// Placeholder connection type.
    pub const Conn = struct {
        id: u16 = 0,
    };

    /// Scripted behavior for one accept call.
    pub const AcceptOp = union(enum) {
        conn: u16,
        none,
        would_block,
    };

    /// Scripted behavior for one `read` call.
    pub const ReadOp = union(enum) {
        bytes: []const u8,
        would_block,
        closed,
        eof,
    };

    /// Scripted behavior for one `write` call.
    pub const WriteOp = union(enum) {
        accept: usize,
        would_block,
        closed,
    };

    /// Return captured write bytes.
    pub fn written(self: *const MockNet) []const u8 {
        return self.write_capture[0..self.write_capture_len];
    }

    /// Reset write capture and script cursor.
    pub fn resetWrites(self: *MockNet) void {
        self.write_capture_len = 0;
        self.write_index = 0;
    }

    pub fn controlListen(self: *MockNet, _: Address) interfaces_net.NetError!ControlListener {
        return .{ .owner = self };
    }

    pub fn acceptControl(listener: *ControlListener) interfaces_net.NetError!?Conn {
        const self = listener.owner;
        if (self.control_accept_index >= self.control_accept_script.len) {
            return null;
        }

        const op = self.control_accept_script[self.control_accept_index];
        self.control_accept_index += 1;
        return switch (op) {
            .conn => |id| .{ .id = id },
            .none => null,
            .would_block => error.WouldBlock,
        };
    }

    pub fn pasvListen(self: *MockNet, _: interfaces_net.PasvBindHint(Address)) interfaces_net.NetError!PasvListener {
        return .{ .owner = self };
    }

    pub fn pasvLocalAddr(_: *PasvListener) interfaces_net.NetError!Address {
        return .{};
    }

    pub fn acceptData(_: *PasvListener) interfaces_net.NetError!?Conn {
        return null;
    }

    pub fn closeListener(_: *PasvListener) void {}

    pub fn read(self: *MockNet, _: *Conn, out: []u8) interfaces_net.NetError!usize {
        if (self.read_index >= self.read_script.len) {
            return error.WouldBlock;
        }

        const op = self.read_script[self.read_index];
        self.read_index += 1;

        return switch (op) {
            .would_block => error.WouldBlock,
            .closed => error.Closed,
            .eof => 0,
            .bytes => |chunk| blk: {
                const n = @min(chunk.len, out.len);
                std.mem.copyForwards(u8, out[0..n], chunk[0..n]);
                break :blk n;
            },
        };
    }

    pub fn write(self: *MockNet, _: *Conn, data: []const u8) interfaces_net.NetError!usize {
        var accepted: usize = data.len;

        if (self.write_index < self.write_script.len) {
            const op = self.write_script[self.write_index];
            self.write_index += 1;
            accepted = switch (op) {
                .would_block => return error.WouldBlock,
                .closed => return error.Closed,
                .accept => |count| @min(count, data.len),
            };
        }

        const available = self.write_capture.len - self.write_capture_len;
        if (accepted > available) {
            return error.Io;
        }

        std.mem.copyForwards(
            u8,
            self.write_capture[self.write_capture_len .. self.write_capture_len + accepted],
            data[0..accepted],
        );
        self.write_capture_len += accepted;
        return accepted;
    }

    pub fn closeConn(self: *MockNet, conn: *const Conn) void {
        if (self.closed_conn_len >= self.closed_conn_ids.len) return;
        self.closed_conn_ids[self.closed_conn_len] = conn.id;
        self.closed_conn_len += 1;
    }
};

const testing = std.testing;

test "mock net read and write scripts" {
    var net: MockNet = .{
        .read_script = &.{
            .{ .bytes = "ab" },
            .would_block,
            .closed,
        },
        .write_script = &.{
            .{ .accept = 1 },
            .would_block,
            .closed,
        },
    };
    var conn: MockNet.Conn = .{};

    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 2), try net.read(&conn, buf[0..]));
    try testing.expect(std.mem.eql(u8, "ab", buf[0..2]));
    try testing.expectError(error.WouldBlock, net.read(&conn, buf[0..]));
    try testing.expectError(error.Closed, net.read(&conn, buf[0..]));

    try testing.expectEqual(@as(usize, 1), try net.write(&conn, "xyz"));
    try testing.expect(std.mem.eql(u8, "x", net.written()));
    try testing.expectError(error.WouldBlock, net.write(&conn, "yz"));
    try testing.expectError(error.Closed, net.write(&conn, "yz"));
}
