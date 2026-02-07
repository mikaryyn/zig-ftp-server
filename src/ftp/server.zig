const std = @import("std");
const interfaces_net = @import("interfaces_net.zig");
const interfaces_fs = @import("interfaces_fs.zig");
const control = @import("control.zig");
const replies = @import("replies.zig");
const commands = @import("commands.zig");
const session_mod = @import("session.zig");
const misc = @import("misc.zig");
const mock_vfs = @import("mock_vfs.zig");

/// Single-session FTP server core for Milestone 5.
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
        cwd: ?Fs.Cwd = null,
        pasv_listener: ?Net.PasvListener = null,
        data_conn: ?Net.Conn = null,

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

            if (self.control_conn == null) {
                try self.acceptPrimaryConn();
            } else {
                try self.rejectExtraConn();
            }

            try self.flushReplies();
            try self.pollPasvAccept();

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
            self.cwd = null;
            self.pasv_listener = null;
            self.data_conn = null;
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
                .pasv => try self.handlePasv(),
                .list, .retr, .stor => try self.handleTransferCommand(),
                .pwd => try self.handlePwd(),
                .cwd => try self.handleCwd(parsed.argument),
                .cdup => try self.handleCdup(),
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
                            self.cwd = self.fs.cwdInit() catch |err| {
                                try self.queueFsError(err);
                                self.session.auth_state = .NeedUser;
                                self.session.cwd_ready = false;
                                self.cwd = null;
                                return;
                            };
                            self.session.auth_state = .Authed;
                            self.session.cwd_ready = true;
                            try self.queueLine(230, "User logged in");
                        } else {
                            self.session.auth_state = .NeedUser;
                            self.session.cwd_ready = false;
                            self.cwd = null;
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
                "PASV",
            };
            self.reply_writer.queueFeat(features[0..]) catch return error.Io;
        }

        fn queueLine(self: *Self, code: u16, text: []const u8) interfaces_net.NetError!void {
            self.reply_writer.queueLine(code, text) catch return error.Io;
        }

        fn handlePwd(self: *Self) interfaces_net.NetError!void {
            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            const split = self.storage.scratch.len / 2;
            if (split == 0) {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            }
            const pwd = self.fs.cwdPwd(cwd, self.storage.scratch[0..split]) catch |err| {
                try self.queueFsError(err);
                return;
            };
            const msg = std.fmt.bufPrint(self.storage.scratch[split..], "\"{s}\"", .{pwd}) catch {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            try self.queueLine(257, msg);
        }

        fn handleCwd(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            const trimmed = std.mem.trim(u8, arg, " ");
            if (trimmed.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            self.fs.cwdChange(cwd, trimmed) catch |err| {
                try self.queueFsError(err);
                return;
            };
            try self.queueLine(250, "Directory successfully changed");
        }

        fn handleCdup(self: *Self) interfaces_net.NetError!void {
            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            self.fs.cwdUp(cwd) catch |err| {
                try self.queueFsError(err);
                return;
            };
            try self.queueLine(250, "Directory successfully changed");
        }

        fn handlePasv(self: *Self) interfaces_net.NetError!void {
            self.closePassiveResources();

            const listener = self.net.pasvListen(.{}) catch {
                self.session.pasv_state = .PasvIdle;
                try self.queueLine(425, "Can't open data connection");
                return;
            };
            self.pasv_listener = listener;
            self.session.pasv_state = .PasvListening;

            const addr = self.net.pasvLocalAddr(&self.pasv_listener.?) catch {
                self.closePassiveResources();
                try self.queueLine(425, "Can't open data connection");
                return;
            };

            const split = self.storage.scratch.len / 2;
            if (split == 0) {
                self.closePassiveResources();
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            }
            const tuple_buf = self.storage.scratch[0..split];
            const msg_buf = self.storage.scratch[split..];

            const tuple = Net.formatPasvAddress(&addr, tuple_buf) catch {
                self.closePassiveResources();
                try self.queueLine(425, "Can't open data connection");
                return;
            };
            const msg = std.fmt.bufPrint(msg_buf, "Entering Passive Mode ({s})", .{tuple}) catch {
                self.closePassiveResources();
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            try self.queueLine(227, msg);
        }

        fn handleTransferCommand(self: *Self) interfaces_net.NetError!void {
            if (self.session.pasv_state == .PasvIdle) {
                try self.queueLine(425, "Use PASV first");
                return;
            }
            try self.queueLine(502, "Command not implemented");
        }

        fn pollPasvAccept(self: *Self) interfaces_net.NetError!void {
            if (self.session.pasv_state != .PasvListening) return;
            if (self.pasv_listener == null) {
                self.session.pasv_state = .PasvIdle;
                return;
            }
            if (self.data_conn != null) return;

            const maybe_data = self.net.acceptData(&self.pasv_listener.?) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    self.closePassiveResources();
                    return err;
                },
            };
            if (maybe_data == null) return;

            self.data_conn = maybe_data.?;
            self.session.pasv_state = .DataConnected;
        }

        fn requireCwd(self: *Self) ?*Fs.Cwd {
            if (!self.session.cwd_ready) return null;
            if (self.cwd == null) return null;
            return &self.cwd.?;
        }

        fn queueFsError(self: *Self, err: interfaces_fs.FsError) interfaces_net.NetError!void {
            const mapped = mapFsError(err);
            try self.queueLine(mapped.code, mapped.text);
        }

        fn mapFsError(err: interfaces_fs.FsError) struct { code: u16, text: []const u8 } {
            return switch (err) {
                error.InvalidPath => .{ .code = 553, .text = "Requested action not taken. File name not allowed" },
                error.NoSpace => .{ .code = 452, .text = "Insufficient storage space" },
                error.Io => .{ .code = 451, .text = "Requested action aborted: local error in processing" },
                error.PermissionDenied, error.ReadOnly => .{ .code = 550, .text = "Permission denied" },
                error.NotFound => .{ .code = 550, .text = "File not found" },
                error.Exists => .{ .code = 550, .text = "File exists" },
                else => .{ .code = 550, .text = "Requested action not taken" },
            };
        }

        fn closePassiveResources(self: *Self) void {
            if (self.data_conn) |*conn| {
                self.net.closeConn(conn);
            }
            self.data_conn = null;

            if (self.pasv_listener) |*listener| {
                self.net.closeListener(listener);
            }
            self.pasv_listener = null;
            self.session.pasv_state = .PasvIdle;
        }

        fn closeControlConn(self: *Self) void {
            self.closePassiveResources();
            if (self.control_conn) |*conn| {
                self.net.closeConn(conn);
            }
            self.control_conn = null;
            self.cwd = null;
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
    pub const Cwd = mock_vfs.MockVfs.Cwd;
    pub const FileReader = struct {};
    pub const FileWriter = struct {};
    pub const DirIter = struct {};
    vfs: mock_vfs.MockVfs = .{},

    pub fn cwdInit(self: *MockFs) interfaces_fs.FsError!Cwd {
        return self.vfs.cwdInit();
    }
    pub fn cwdPwd(self: *MockFs, cwd: *const Cwd, out: []u8) interfaces_fs.FsError![]const u8 {
        return self.vfs.cwdPwd(cwd, out);
    }
    pub fn cwdChange(self: *MockFs, cwd: *Cwd, path: []const u8) interfaces_fs.FsError!void {
        try self.vfs.cwdChange(cwd, path);
    }
    pub fn cwdUp(self: *MockFs, cwd: *Cwd) interfaces_fs.FsError!void {
        try self.vfs.cwdUp(cwd);
    }
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
        " PASV\r\n" ++
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

test "server PASV lifecycle closes prior listener and data conn" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .data_accept_script = &.{
            .{ .conn = 7 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nPASV\r\nQUIT\r\n" },
        },
        .pasv_local_addr = .{
            .ip = .{ 10, 11, 12, 13 },
            .port = 2125,
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
    while (i < 20) : (i += 1) {
        try server.tick(0);
    }

    const expected_227 = "227 Entering Passive Mode (10,11,12,13,8,77)\r\n";
    const written = net.written();
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, expected_227));

    try testing.expectEqual(@as(usize, 2), net.closed_listener_len);
    try testing.expectEqual(@as(usize, 2), net.closed_conn_len);
    try testing.expectEqual(@as(u16, 7), net.closed_conn_ids[0]);
    try testing.expectEqual(@as(u16, 1), net.closed_conn_ids[1]);
}

test "server requires PASV before LIST RETR STOR" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nLIST\r\nRETR file.bin\r\nSTOR upload.bin\r\nQUIT\r\n" },
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
    while (i < 20) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    const expected = "425 Use PASV first\r\n";
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, written, expected));
}

test "server handles PWD CWD and CDUP" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPWD\r\nCWD pub\r\nPWD\r\nCDUP\r\nPWD\r\nQUIT\r\n" },
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
    while (i < 20) : (i += 1) {
        try server.tick(0);
    }

    const expected =
        "220 FTP Server Ready\r\n" ++
        "331 User name okay, need password\r\n" ++
        "230 User logged in\r\n" ++
        "257 \"/\"\r\n" ++
        "250 Directory successfully changed\r\n" ++
        "257 \"/pub\"\r\n" ++
        "250 Directory successfully changed\r\n" ++
        "257 \"/\"\r\n" ++
        "221 Bye\r\n";
    try testing.expect(std.mem.eql(u8, expected, net.written()));
}

test "server maps CWD fs errors to replies" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nCWD missing\r\nCWD locked\r\nCWD ioerr\r\nQUIT\r\n" },
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
    while (i < 20) : (i += 1) {
        try server.tick(0);
    }

    try testing.expect(std.mem.indexOf(u8, net.written(), "550 File not found\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, net.written(), "550 Permission denied\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, net.written(), "451 Requested action aborted: local error in processing\r\n") != null);
}
