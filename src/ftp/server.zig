const std = @import("std");
const interfaces_net = @import("interfaces_net.zig");
const interfaces_fs = @import("interfaces_fs.zig");
const control = @import("control.zig");
const replies = @import("replies.zig");
const commands = @import("commands.zig");
const session_mod = @import("session.zig");
const misc = @import("misc.zig");

/// Single-session FTP server core for Milestone 4.
pub fn FtpServer(comptime Net: type, comptime Fs: type) type {
    interfaces_net.validate(Net);
    interfaces_fs.validate(Fs);

    return struct {
        const Self = @This();

        net: *Net,
        fs: *Fs,
        config: misc.Config,
        storage: *misc.Storage,
        control_listener: Net.ControlListener,
        control_conn: ?Net.Conn = null,
        line_reader: control.LineReader(Net),
        reply_writer: replies.ReplyWriter(Net),
        session: *session_mod.Session,

        pub fn initNoHeap(
            net: *Net,
            fs: *Fs,
            control_listener: Net.ControlListener,
            config: misc.Config,
            storage: *misc.Storage,
        ) Self {
            storage.session = .{};
            return .{
                .net = net,
                .fs = fs,
                .config = config,
                .storage = storage,
                .control_listener = control_listener,
                .line_reader = control.LineReader(Net).init(storage.command_buf),
                .reply_writer = replies.ReplyWriter(Net).init(storage.reply_buf),
                .session = &storage.session,
            };
        }

        /// Drive one bounded, non-blocking server tick.
        pub fn tick(self: *Self, now_millis: u64) interfaces_net.NetError!void {
            _ = now_millis;
            _ = self.fs;

            if (self.control_conn == null) {
                try self.acceptPrimaryConn();
            } else {
                try self.rejectExtraConn();
            }

            try self.flushReplies();

            if (self.control_conn == null) return;
            if (self.reply_writer.isPending()) return;

            if (self.session.auth_state == .Closing) {
                self.closeControlConn();
                return;
            }

            const conn = &self.control_conn.?;
            const event = self.line_reader.poll(self.net, conn) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Closed => {
                    self.closeControlConn();
                    return;
                },
                else => return err,
            };

            switch (event) {
                .none => return,
                .too_long => try self.queueLine(500, "Line too long"),
                .line => |line| {
                    if (line.len == 0) return;
                    try self.handleCommand(commands.parse(line));
                },
            }
        }

        fn acceptPrimaryConn(self: *Self) interfaces_net.NetError!void {
            const maybe_conn = self.net.acceptControl(&self.control_listener) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (maybe_conn == null) return;

            self.control_conn = maybe_conn.?;
            self.session.* = .{};
            self.line_reader = control.LineReader(Net).init(self.storage.command_buf);
            self.reply_writer = replies.ReplyWriter(Net).init(self.storage.reply_buf);
            try self.queueLine(220, self.config.banner);
        }

        fn rejectExtraConn(self: *Self) interfaces_net.NetError!void {
            const maybe_extra = self.net.acceptControl(&self.control_listener) catch |err| switch (err) {
                error.WouldBlock => return,
                else => return err,
            };
            if (maybe_extra == null) return;

            var extra = maybe_extra.?;
            _ = self.net.write(&extra, "421 Too many users\r\n") catch {};
            self.net.closeConn(&extra);
        }

        fn flushReplies(self: *Self) interfaces_net.NetError!void {
            if (!self.reply_writer.isPending()) return;
            if (self.control_conn == null) return;

            const conn = &self.control_conn.?;
            _ = try self.reply_writer.flush(self.net, conn);
        }

        fn handleCommand(self: *Self, parsed: commands.Parsed) interfaces_net.NetError!void {
            if (parsed.command == .quit) {
                self.session.auth_state = .Closing;
                try self.queueLine(221, "Bye");
                return;
            }

            if (self.session.auth_state != .Authed) {
                try self.handlePreAuth(parsed);
                return;
            }

            switch (parsed.command) {
                .user, .pass => try self.queueLine(230, "User logged in"),
                .noop => try self.queueLine(200, "OK"),
                .syst => try self.queueLine(215, "UNIX Type: L8"),
                .type_ => try self.handleType(parsed.argument),
                .feat => try self.queueFeat(),
                .unknown => try self.queueLine(502, "Command not implemented"),
                .quit => unreachable,
            }
        }

        fn handlePreAuth(self: *Self, parsed: commands.Parsed) interfaces_net.NetError!void {
            switch (self.session.auth_state) {
                .NeedUser => switch (parsed.command) {
                    .user => {
                        if (parsed.argument.len == 0) {
                            try self.queueLine(501, "Missing username");
                            return;
                        }
                        if (std.mem.eql(u8, parsed.argument, self.config.user)) {
                            self.session.auth_state = .NeedPass;
                            try self.queueLine(331, "User name okay, need password");
                        } else {
                            try self.queueLine(530, "Not logged in");
                        }
                    },
                    .pass => try self.queueLine(530, "Please login with USER and PASS"),
                    else => try self.queueLine(530, "Please login with USER and PASS"),
                },
                .NeedPass => switch (parsed.command) {
                    .user => {
                        if (parsed.argument.len == 0) {
                            try self.queueLine(501, "Missing username");
                            return;
                        }
                        if (std.mem.eql(u8, parsed.argument, self.config.user)) {
                            try self.queueLine(331, "User name okay, need password");
                        } else {
                            self.session.auth_state = .NeedUser;
                            try self.queueLine(530, "Not logged in");
                        }
                    },
                    .pass => {
                        if (parsed.argument.len == 0) {
                            try self.queueLine(501, "Missing password");
                            return;
                        }
                        if (std.mem.eql(u8, parsed.argument, self.config.password)) {
                            self.session.auth_state = .Authed;
                            try self.queueLine(230, "User logged in");
                        } else {
                            self.session.auth_state = .NeedUser;
                            try self.queueLine(530, "Not logged in");
                        }
                    },
                    else => try self.queueLine(530, "Please login with USER and PASS"),
                },
                .Authed, .Closing => unreachable,
            }
        }

        fn handleType(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            const trimmed = std.mem.trim(u8, arg, " ");
            if (std.ascii.eqlIgnoreCase(trimmed, "I") or std.ascii.eqlIgnoreCase(trimmed, "A")) {
                self.session.transfer_type = .binary;
                try self.queueLine(200, "Type set to I");
            } else {
                try self.queueLine(504, "Command not implemented for that parameter");
            }
        }

        fn queueFeat(self: *Self) interfaces_net.NetError!void {
            const features = [_][]const u8{
                "TYPE I",
            };
            self.reply_writer.queueFeat(features[0..]) catch return error.Io;
        }

        fn queueLine(self: *Self, code: u16, text: []const u8) interfaces_net.NetError!void {
            self.reply_writer.queueLine(code, text) catch return error.Io;
        }

        fn closeControlConn(self: *Self) void {
            if (self.control_conn) |*conn| {
                self.net.closeConn(conn);
            }
            self.control_conn = null;
            self.session.* = .{};
            self.line_reader = control.LineReader(Net).init(self.storage.command_buf);
            self.reply_writer = replies.ReplyWriter(Net).init(self.storage.reply_buf);
        }
    };
}

const mock_net = @import("mock_net.zig");
const limits = @import("limits.zig");
const testing = std.testing;

const MockFs = struct {
    pub const Cwd = struct {};
    pub const FileReader = struct {};
    pub const FileWriter = struct {};
    pub const DirIter = struct {};

    pub fn cwdInit(_: *MockFs) interfaces_fs.FsError!Cwd {
        return .{};
    }
    pub fn cwdPwd(_: *MockFs, _: *const Cwd, out: []u8) interfaces_fs.FsError![]const u8 {
        return out[0..0];
    }
    pub fn cwdChange(_: *MockFs, _: *Cwd, _: []const u8) interfaces_fs.FsError!void {}
    pub fn cwdUp(_: *MockFs, _: *Cwd) interfaces_fs.FsError!void {}
    pub fn dirOpen(_: *MockFs, _: *const Cwd, _: ?[]const u8) interfaces_fs.FsError!DirIter {
        return .{};
    }
    pub fn dirNext(_: *MockFs, _: *DirIter) interfaces_fs.FsError!?interfaces_fs.DirEntry {
        return null;
    }
    pub fn dirClose(_: *MockFs, _: *DirIter) void {}
    pub fn openRead(_: *MockFs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!FileReader {
        return .{};
    }
    pub fn openWriteTrunc(_: *MockFs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!FileWriter {
        return .{};
    }
    pub fn readFile(_: *MockFs, _: *FileReader, _: []u8) interfaces_fs.FsError!usize {
        return 0;
    }
    pub fn writeFile(_: *MockFs, _: *FileWriter, _: []const u8) interfaces_fs.FsError!usize {
        return 0;
    }
    pub fn closeRead(_: *MockFs, _: *FileReader) void {}
    pub fn closeWrite(_: *MockFs, _: *FileWriter) void {}
    pub fn delete(_: *MockFs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!void {}
    pub fn rename(_: *MockFs, _: *const Cwd, _: []const u8, _: []const u8) interfaces_fs.FsError!void {}
};

test "server handles login flow and basic commands" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nSYST\r\nTYPE I\r\nFEAT\r\nQUIT\r\n" },
        },
    };
    var fs: MockFs = .{};
    const listener = try net.controlListen(.{});

    var cmd_buf: [limits.command_max]u8 = undefined;
    var reply_buf: [limits.reply_max]u8 = undefined;
    var transfer_buf: [limits.transfer_max]u8 = undefined;
    var scratch_buf: [limits.scratch_max]u8 = undefined;
    var storage = misc.Storage.init(cmd_buf[0..], reply_buf[0..], transfer_buf[0..], scratch_buf[0..]);
    storage.session = .{};

    const Server = FtpServer(mock_net.MockNet, MockFs);
    var server = Server.initNoHeap(&net, &fs, listener, .{
        .user = "test",
        .password = "secret",
        .banner = "FTP Server Ready",
    }, &storage);

    var i: usize = 0;
    while (i < 16) : (i += 1) {
        try server.tick(0);
    }

    const expected =
        "220 FTP Server Ready\r\n" ++
        "331 User name okay, need password\r\n" ++
        "230 User logged in\r\n" ++
        "215 UNIX Type: L8\r\n" ++
        "200 Type set to I\r\n" ++
        "211-Features:\r\n" ++
        " TYPE I\r\n" ++
        "211 End\r\n" ++
        "221 Bye\r\n";
    try testing.expect(std.mem.eql(u8, expected, net.written()));
    try testing.expectEqual(@as(usize, 1), net.closed_conn_len);
    try testing.expectEqual(@as(u16, 1), net.closed_conn_ids[0]);
}

test "server rejects second control connection with 421" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
            .{ .conn = 2 },
        },
        .read_script = &.{
            .{ .bytes = "QUIT\r\n" },
        },
    };
    var fs: MockFs = .{};
    const listener = try net.controlListen(.{});

    var cmd_buf: [limits.command_max]u8 = undefined;
    var reply_buf: [limits.reply_max]u8 = undefined;
    var transfer_buf: [limits.transfer_max]u8 = undefined;
    var scratch_buf: [limits.scratch_max]u8 = undefined;
    var storage = misc.Storage.init(cmd_buf[0..], reply_buf[0..], transfer_buf[0..], scratch_buf[0..]);
    storage.session = .{};

    const Server = FtpServer(mock_net.MockNet, MockFs);
    var server = Server.initNoHeap(&net, &fs, listener, .{
        .user = "test",
        .password = "secret",
    }, &storage);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        try server.tick(0);
    }

    try testing.expect(std.mem.indexOf(u8, net.written(), "421 Too many users\r\n") != null);
    try testing.expectEqual(@as(usize, 2), net.closed_conn_len);
    try testing.expectEqual(@as(u16, 2), net.closed_conn_ids[0]);
    try testing.expectEqual(@as(u16, 1), net.closed_conn_ids[1]);
}
