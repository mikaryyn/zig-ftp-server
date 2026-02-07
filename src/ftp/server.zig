const std = @import("std");
const interfaces_net = @import("interfaces_net.zig");
const interfaces_fs = @import("interfaces_fs.zig");
const control = @import("control.zig");
const replies = @import("replies.zig");
const commands = @import("commands.zig");
const session_mod = @import("session.zig");
const misc = @import("misc.zig");
const transfer = @import("transfer.zig");
const mock_vfs = @import("mock_vfs.zig");

/// Single-session FTP server core with PASV and LIST support.
pub fn FtpServer(comptime Net: type, comptime Fs: type) type {
    interfaces_net.validate(Net);
    interfaces_fs.validate(Fs);

    return struct {
        const Self = @This();
        const has_make_dir = @hasDecl(Fs, "makeDir");
        const has_remove_dir = @hasDecl(Fs, "removeDir");
        const has_file_size = @hasDecl(Fs, "fileSize");
        const has_file_mtime = @hasDecl(Fs, "fileMtime");

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
        list_iter: ?Fs.DirIter = null,
        list_transfer: transfer.ListTransfer = .{},
        file_reader: ?Fs.FileReader = null,
        retr_transfer: transfer.RetrTransfer = .{},
        file_writer: ?Fs.FileWriter = null,
        stor_transfer: transfer.StorTransfer = .{},

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
            try self.driveListTransfer();
            try self.driveRetrTransfer();
            try self.driveStorTransfer();

            if (self.control_conn == null) return;
            if (self.reply_writer.isPending()) return;
            if (self.list_transfer.state != .idle) return;
            if (self.retr_transfer.state != .idle) return;
            if (self.stor_transfer.state != .idle) return;

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
            self.closePassiveResources();
            self.closeListIter();
            self.list_transfer.reset();
            self.closeFileReader();
            self.retr_transfer.reset();
            self.closeFileWriter();
            self.stor_transfer.reset();
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

            if (self.session.rename_from_len > 0 and parsed.command != .rnto) {
                try self.queueLine(503, "Bad sequence of commands");
                return;
            }

            switch (parsed.command) {
                .user, .pass => try self.queueLine(230, "User logged in"),
                .noop => try self.queueLine(200, "OK"),
                .syst => try self.queueLine(215, "UNIX Type: L8"),
                .type_ => try self.handleType(parsed.argument),
                .feat => try self.queueFeat(),
                .pasv => try self.handlePasv(),
                .list => try self.handleList(parsed.argument),
                .retr => try self.handleRetr(parsed.argument),
                .stor => try self.handleStor(parsed.argument),
                .pwd => try self.handlePwd(),
                .cwd => try self.handleCwd(parsed.argument),
                .cdup => try self.handleCdup(),
                .dele => try self.handleDele(parsed.argument),
                .rnfr => try self.handleRnfr(parsed.argument),
                .rnto => try self.handleRnto(parsed.argument),
                .mkd => try self.handleMkd(parsed.argument),
                .rmd => try self.handleRmd(parsed.argument),
                .size => try self.handleSize(parsed.argument),
                .mdtm => try self.handleMdtm(parsed.argument),
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
            if (std.ascii.eqlIgnoreCase(trimmed, "I")) {
                self.session.transfer_type = .binary;
                try self.queueLine(200, "Type set to I");
            } else if (std.ascii.eqlIgnoreCase(trimmed, "A")) {
                self.session.transfer_type = .binary;
                try self.queueLine(200, "Type set to A");
            } else {
                try self.queueLine(504, "Command not implemented for that parameter");
            }
        }

        fn queueFeat(self: *Self) interfaces_net.NetError!void {
            var features: [4][]const u8 = undefined;
            var len: usize = 0;
            features[len] = "TYPE I";
            len += 1;
            features[len] = "PASV";
            len += 1;
            if (has_file_size) {
                features[len] = "SIZE";
                len += 1;
            }
            if (has_file_mtime) {
                features[len] = "MDTM";
                len += 1;
            }
            self.reply_writer.queueFeat(features[0..len]) catch return error.Io;
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
            self.closeListIter();
            self.list_transfer.reset();
            self.closeFileReader();
            self.retr_transfer.reset();
            self.closeFileWriter();
            self.stor_transfer.reset();
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

        fn handleList(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (self.session.pasv_state == .PasvIdle) {
                try self.queueLine(425, "Use PASV first");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };

            const trimmed = std.mem.trim(u8, arg, " ");
            const opt_path: ?[]const u8 = if (trimmed.len == 0) null else trimmed;
            const iter = self.fs.dirOpen(cwd, opt_path) catch |err| {
                try self.queueFsError(err);
                return;
            };

            self.closeListIter();
            self.list_iter = iter;
            self.list_transfer = .{
                .state = .list_waiting_accept,
            };
        }

        fn handleRetr(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (self.session.pasv_state == .PasvIdle) {
                try self.queueLine(425, "Use PASV first");
                return;
            }

            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            const reader = self.fs.openRead(cwd, path) catch |err| {
                try self.queueFsError(err);
                return;
            };

            self.closeFileReader();
            self.file_reader = reader;
            self.retr_transfer = .{
                .state = .retr_waiting_accept,
            };
        }

        fn handleStor(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (self.session.pasv_state == .PasvIdle) {
                try self.queueLine(425, "Use PASV first");
                return;
            }

            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            const writer = self.fs.openWriteTrunc(cwd, path) catch |err| {
                try self.queueFsError(err);
                return;
            };

            self.closeFileWriter();
            self.file_writer = writer;
            self.stor_transfer = .{
                .state = .stor_waiting_accept,
            };
        }

        fn handleDele(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            self.fs.delete(cwd, path) catch |err| {
                try self.queueFsError(err);
                return;
            };
            try self.queueLine(250, "Requested file action okay, completed");
        }

        fn handleRnfr(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }
            if (path.len > self.session.rename_from.len) {
                try self.queueLine(553, "Requested action not taken. File name not allowed");
                return;
            }

            std.mem.copyForwards(u8, self.session.rename_from[0..path.len], path);
            self.session.rename_from_len = path.len;
            try self.queueLine(350, "Requested file action pending further information");
        }

        fn handleRnto(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (self.session.rename_from_len == 0) {
                try self.queueLine(503, "Bad sequence of commands");
                return;
            }

            const to_path = std.mem.trim(u8, arg, " ");
            if (to_path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            const from_path = self.session.rename_from[0..self.session.rename_from_len];
            self.fs.rename(cwd, from_path, to_path) catch |err| {
                self.session.rename_from_len = 0;
                try self.queueFsError(err);
                return;
            };
            self.session.rename_from_len = 0;
            try self.queueLine(250, "Requested file action okay, completed");
        }

        fn handleMkd(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (comptime !has_make_dir) {
                try self.queueLine(502, "Command not implemented");
                return;
            }

            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            self.fs.makeDir(cwd, path) catch |err| {
                if (err == error.Unsupported) {
                    try self.queueLine(502, "Command not implemented");
                    return;
                }
                try self.queueFsError(err);
                return;
            };

            const msg = std.fmt.bufPrint(self.storage.scratch, "\"{s}\"", .{path}) catch {
                try self.queueLine(257, "Directory created");
                return;
            };
            try self.queueLine(257, msg);
        }

        fn handleRmd(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (comptime !has_remove_dir) {
                try self.queueLine(502, "Command not implemented");
                return;
            }

            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            self.fs.removeDir(cwd, path) catch |err| {
                if (err == error.Unsupported) {
                    try self.queueLine(502, "Command not implemented");
                    return;
                }
                try self.queueFsError(err);
                return;
            };
            try self.queueLine(250, "Requested file action okay, completed");
        }

        fn handleSize(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (comptime !has_file_size) {
                try self.queueLine(502, "Command not implemented");
                return;
            }

            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            const size = self.fs.fileSize(cwd, path) catch |err| {
                if (err == error.Unsupported) {
                    try self.queueLine(502, "Command not implemented");
                    return;
                }
                try self.queueFsError(err);
                return;
            };

            const msg = std.fmt.bufPrint(self.storage.scratch, "{d}", .{size}) catch {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            try self.queueLine(213, msg);
        }

        fn handleMdtm(self: *Self, arg: []const u8) interfaces_net.NetError!void {
            if (comptime !has_file_mtime) {
                try self.queueLine(502, "Command not implemented");
                return;
            }

            const path = std.mem.trim(u8, arg, " ");
            if (path.len == 0) {
                try self.queueLine(501, "Syntax error in parameters or arguments");
                return;
            }

            const cwd = self.requireCwd() orelse {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            const unix_seconds = self.fs.fileMtime(cwd, path) catch |err| {
                if (err == error.Unsupported) {
                    try self.queueLine(502, "Command not implemented");
                    return;
                }
                try self.queueFsError(err);
                return;
            };
            if (unix_seconds < 0) {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            }

            const ts = std.time.epoch.EpochSeconds{ .secs = @intCast(unix_seconds) };
            const year_day = ts.getEpochDay().calculateYearDay();
            const month_day = year_day.calculateMonthDay();
            const day_seconds = ts.getDaySeconds();

            const msg = std.fmt.bufPrint(self.storage.scratch, "{d:0>4}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}", .{
                year_day.year,
                month_day.month.numeric(),
                month_day.day_index + 1,
                day_seconds.getHoursIntoDay(),
                day_seconds.getMinutesIntoHour(),
                day_seconds.getSecondsIntoMinute(),
            }) catch {
                try self.queueLine(451, "Requested action aborted: local error in processing");
                return;
            };
            try self.queueLine(213, msg);
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

        fn driveListTransfer(self: *Self) interfaces_net.NetError!void {
            if (self.list_transfer.state == .idle) return;
            if (self.reply_writer.isPending()) return;

            if (self.data_conn == null) {
                if (self.session.pasv_state == .PasvListening) return;
                try self.abortListTransfer(425, "Can't open data connection");
                return;
            }

            if (self.list_transfer.state == .list_waiting_accept) {
                try self.queueLine(150, "Here comes the directory listing");
                self.list_transfer.state = .list_streaming;
                self.session.pasv_state = .Transferring;
                return;
            }

            if (self.list_transfer.line_off < self.list_transfer.line_len) {
                try self.flushListLine();
                return;
            }

            if (self.list_transfer.exhausted) {
                try self.finishListTransfer();
                return;
            }

            if (self.list_iter == null) {
                try self.abortListTransfer(451, "Requested action aborted: local error in processing");
                return;
            }
            const entry_opt = self.fs.dirNext(&self.list_iter.?) catch |err| {
                try self.abortListFsError(err);
                return;
            };
            if (entry_opt == null) {
                self.list_transfer.exhausted = true;
                try self.finishListTransfer();
                return;
            }

            const line = transfer.formatListEntry(self.storage.transfer_buf, entry_opt.?) catch {
                try self.abortListTransfer(451, "Requested action aborted: local error in processing");
                return;
            };
            self.list_transfer.line_len = line.len;
            self.list_transfer.line_off = 0;
            try self.flushListLine();
        }

        fn driveRetrTransfer(self: *Self) interfaces_net.NetError!void {
            if (self.retr_transfer.state == .idle) return;
            if (self.reply_writer.isPending()) return;

            if (self.data_conn == null) {
                if (self.session.pasv_state == .PasvListening) return;
                try self.abortRetrTransfer(425, "Can't open data connection");
                return;
            }

            if (self.retr_transfer.state == .retr_waiting_accept) {
                try self.queueLine(150, "Opening data connection");
                self.retr_transfer.state = .retr_streaming;
                self.session.pasv_state = .Transferring;
                return;
            }

            if (self.retr_transfer.chunk_off < self.retr_transfer.chunk_len) {
                try self.flushRetrChunk();
                return;
            }

            if (self.retr_transfer.eof) {
                try self.finishRetrTransfer();
                return;
            }

            if (self.file_reader == null) {
                try self.abortRetrTransfer(451, "Requested action aborted: local error in processing");
                return;
            }

            const n = self.fs.readFile(&self.file_reader.?, self.storage.transfer_buf) catch |err| {
                try self.abortRetrFsError(err);
                return;
            };
            if (n == 0) {
                self.retr_transfer.eof = true;
                try self.finishRetrTransfer();
                return;
            }

            self.retr_transfer.chunk_len = n;
            self.retr_transfer.chunk_off = 0;
            try self.flushRetrChunk();
        }

        fn driveStorTransfer(self: *Self) interfaces_net.NetError!void {
            if (self.stor_transfer.state == .idle) return;
            if (self.reply_writer.isPending()) return;

            if (self.data_conn == null) {
                if (self.session.pasv_state == .PasvListening) return;
                try self.abortStorTransfer(425, "Can't open data connection");
                return;
            }

            if (self.stor_transfer.state == .stor_waiting_accept) {
                try self.queueLine(150, "Opening data connection");
                self.stor_transfer.state = .stor_streaming;
                self.session.pasv_state = .Transferring;
                return;
            }

            if (self.stor_transfer.chunk_off < self.stor_transfer.chunk_len) {
                try self.flushStorChunk();
                return;
            }

            if (self.stor_transfer.eof) {
                try self.finishStorTransfer();
                return;
            }

            if (self.file_writer == null) {
                try self.abortStorTransfer(451, "Requested action aborted: local error in processing");
                return;
            }

            const n = self.net.read(&self.data_conn.?, self.storage.transfer_buf) catch |err| switch (err) {
                error.WouldBlock => return,
                error.Closed => {
                    self.stor_transfer.eof = true;
                    try self.finishStorTransfer();
                    return;
                },
                else => {
                    try self.abortStorTransfer(426, "Connection closed; transfer aborted");
                    return;
                },
            };

            if (n == 0) {
                self.stor_transfer.eof = true;
                try self.finishStorTransfer();
                return;
            }

            self.stor_transfer.chunk_len = n;
            self.stor_transfer.chunk_off = 0;
            try self.flushStorChunk();
        }

        fn flushListLine(self: *Self) interfaces_net.NetError!void {
            if (self.data_conn == null) {
                try self.abortListTransfer(426, "Connection closed; transfer aborted");
                return;
            }
            const pending = self.storage.transfer_buf[self.list_transfer.line_off..self.list_transfer.line_len];
            const wrote = self.net.write(&self.data_conn.?, pending) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    try self.abortListTransfer(426, "Connection closed; transfer aborted");
                    return;
                },
            };
            if (wrote == 0) {
                try self.abortListTransfer(426, "Connection closed; transfer aborted");
                return;
            }
            self.list_transfer.line_off += wrote;
            if (self.list_transfer.line_off >= self.list_transfer.line_len) {
                self.list_transfer.line_off = 0;
                self.list_transfer.line_len = 0;
            }
        }

        fn finishListTransfer(self: *Self) interfaces_net.NetError!void {
            self.closeListIter();
            self.list_transfer.reset();
            self.closePassiveResources();
            try self.queueLine(226, "Directory send OK");
        }

        fn flushRetrChunk(self: *Self) interfaces_net.NetError!void {
            if (self.data_conn == null) {
                try self.abortRetrTransfer(426, "Connection closed; transfer aborted");
                return;
            }

            const pending = self.storage.transfer_buf[self.retr_transfer.chunk_off..self.retr_transfer.chunk_len];
            const wrote = self.net.write(&self.data_conn.?, pending) catch |err| switch (err) {
                error.WouldBlock => return,
                else => {
                    try self.abortRetrTransfer(426, "Connection closed; transfer aborted");
                    return;
                },
            };
            if (wrote == 0) {
                try self.abortRetrTransfer(426, "Connection closed; transfer aborted");
                return;
            }

            self.retr_transfer.chunk_off += wrote;
            if (self.retr_transfer.chunk_off >= self.retr_transfer.chunk_len) {
                self.retr_transfer.chunk_off = 0;
                self.retr_transfer.chunk_len = 0;
            }
        }

        fn finishRetrTransfer(self: *Self) interfaces_net.NetError!void {
            self.closeFileReader();
            self.retr_transfer.reset();
            self.closePassiveResources();
            try self.queueLine(226, "Closing data connection");
        }

        fn flushStorChunk(self: *Self) interfaces_net.NetError!void {
            if (self.file_writer == null) {
                try self.abortStorTransfer(451, "Requested action aborted: local error in processing");
                return;
            }

            const pending = self.storage.transfer_buf[self.stor_transfer.chunk_off..self.stor_transfer.chunk_len];
            const wrote = self.fs.writeFile(&self.file_writer.?, pending) catch |err| {
                try self.abortStorFsError(err);
                return;
            };
            if (wrote == 0) {
                try self.abortStorTransfer(451, "Requested action aborted: local error in processing");
                return;
            }

            self.stor_transfer.chunk_off += wrote;
            if (self.stor_transfer.chunk_off >= self.stor_transfer.chunk_len) {
                self.stor_transfer.chunk_off = 0;
                self.stor_transfer.chunk_len = 0;
            }
        }

        fn finishStorTransfer(self: *Self) interfaces_net.NetError!void {
            self.closeFileWriter();
            self.stor_transfer.reset();
            self.closePassiveResources();
            try self.queueLine(226, "Closing data connection");
        }

        fn abortListFsError(self: *Self, err: interfaces_fs.FsError) interfaces_net.NetError!void {
            const mapped = mapFsError(err);
            try self.abortListTransfer(mapped.code, mapped.text);
        }

        fn abortRetrFsError(self: *Self, err: interfaces_fs.FsError) interfaces_net.NetError!void {
            const mapped = mapFsError(err);
            try self.abortRetrTransfer(mapped.code, mapped.text);
        }

        fn abortStorFsError(self: *Self, err: interfaces_fs.FsError) interfaces_net.NetError!void {
            const mapped = mapFsError(err);
            try self.abortStorTransfer(mapped.code, mapped.text);
        }

        fn abortListTransfer(self: *Self, code: u16, text: []const u8) interfaces_net.NetError!void {
            self.closeListIter();
            self.list_transfer.reset();
            self.closePassiveResources();
            try self.queueLine(code, text);
        }

        fn abortRetrTransfer(self: *Self, code: u16, text: []const u8) interfaces_net.NetError!void {
            self.closeFileReader();
            self.retr_transfer.reset();
            self.closePassiveResources();
            try self.queueLine(code, text);
        }

        fn abortStorTransfer(self: *Self, code: u16, text: []const u8) interfaces_net.NetError!void {
            self.closeFileWriter();
            self.stor_transfer.reset();
            self.closePassiveResources();
            try self.queueLine(code, text);
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

        fn closeListIter(self: *Self) void {
            if (self.list_iter) |*iter| {
                self.fs.dirClose(iter);
            }
            self.list_iter = null;
        }

        fn closeFileReader(self: *Self) void {
            if (self.file_reader) |*reader| {
                self.fs.closeRead(reader);
            }
            self.file_reader = null;
        }

        fn closeFileWriter(self: *Self) void {
            if (self.file_writer) |*writer| {
                self.fs.closeWrite(writer);
            }
            self.file_writer = null;
        }

        fn closeControlConn(self: *Self) void {
            self.closeListIter();
            self.list_transfer.reset();
            self.closeFileReader();
            self.retr_transfer.reset();
            self.closeFileWriter();
            self.stor_transfer.reset();
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
    pub const FileReader = mock_vfs.MockVfs.FileReader;
    pub const FileWriter = mock_vfs.MockVfs.FileWriter;
    pub const DirIter = mock_vfs.MockVfs.DirIter;
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
    pub fn dirOpen(self: *MockFs, cwd: *const Cwd, path: ?[]const u8) interfaces_fs.FsError!DirIter {
        return self.vfs.dirOpen(cwd, path);
    }
    pub fn dirNext(self: *MockFs, iter: *DirIter) interfaces_fs.FsError!?interfaces_fs.DirEntry {
        return self.vfs.dirNext(iter);
    }
    pub fn dirClose(self: *MockFs, iter: *DirIter) void {
        self.vfs.dirClose(iter);
    }
    pub fn openRead(self: *MockFs, cwd: *const Cwd, path: []const u8) interfaces_fs.FsError!FileReader {
        return self.vfs.openRead(cwd, path);
    }
    pub fn openWriteTrunc(self: *MockFs, cwd: *const Cwd, path: []const u8) interfaces_fs.FsError!FileWriter {
        return self.vfs.openWriteTrunc(cwd, path);
    }
    pub fn readFile(self: *MockFs, reader: *FileReader, out: []u8) interfaces_fs.FsError!usize {
        return self.vfs.readFile(reader, out);
    }
    pub fn writeFile(self: *MockFs, writer: *FileWriter, src: []const u8) interfaces_fs.FsError!usize {
        return self.vfs.writeFile(writer, src);
    }
    pub fn closeRead(self: *MockFs, reader: *FileReader) void {
        self.vfs.closeRead(reader);
    }
    pub fn closeWrite(self: *MockFs, writer: *FileWriter) void {
        self.vfs.closeWrite(writer);
    }
    pub fn delete(self: *MockFs, cwd: *const Cwd, path: []const u8) interfaces_fs.FsError!void {
        try self.vfs.delete(cwd, path);
    }
    pub fn rename(self: *MockFs, cwd: *const Cwd, from: []const u8, to: []const u8) interfaces_fs.FsError!void {
        try self.vfs.rename(cwd, from, to);
    }
    pub fn makeDir(self: *MockFs, cwd: *const Cwd, path: []const u8) interfaces_fs.FsError!void {
        try self.vfs.makeDir(cwd, path);
    }
    pub fn removeDir(self: *MockFs, cwd: *const Cwd, path: []const u8) interfaces_fs.FsError!void {
        try self.vfs.removeDir(cwd, path);
    }
    pub fn fileSize(self: *MockFs, cwd: *const Cwd, path: []const u8) interfaces_fs.FsError!u64 {
        return self.vfs.fileSize(cwd, path);
    }
    pub fn fileMtime(self: *MockFs, cwd: *const Cwd, path: []const u8) interfaces_fs.FsError!i64 {
        return self.vfs.fileMtime(cwd, path);
    }
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
        " SIZE\r\n" ++
        " MDTM\r\n" ++
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

test "server LIST waits for PASV data accept before 150" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .data_accept_script = &.{
            .none,
            .none,
            .{ .conn = 8 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nLIST\r\nQUIT\r\n" },
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
    while (i < 6) : (i += 1) {
        try server.tick(0);
    }
    try testing.expect(std.mem.indexOf(u8, net.written(), "150 Here comes the directory listing\r\n") == null);

    while (i < 24) : (i += 1) {
        try server.tick(0);
    }
    const written = net.written();
    const idx_150 = std.mem.indexOf(u8, written, "150 Here comes the directory listing\r\n") orelse return error.UnexpectedTestResult;
    const idx_226 = std.mem.indexOf(u8, written, "226 Directory send OK\r\n") orelse return error.UnexpectedTestResult;
    try testing.expect(idx_150 < idx_226);
}

test "server LIST streams lines with CRLF and partial data writes" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .data_accept_script = &.{
            .{ .conn = 9 },
        },
        .write_script = &.{
            .{ .accept = 1024 }, // 220
            .{ .accept = 1024 }, // 331
            .{ .accept = 1024 }, // 230
            .{ .accept = 1024 }, // 227
            .{ .accept = 1024 }, // 150
            .{ .accept = 5 }, // first LIST line partial
            .would_block,
            .{ .accept = 1024 }, // first line remainder
            .{ .accept = 7 }, // second line partial
            .{ .accept = 1024 }, // second line remainder
            .{ .accept = 1024 }, // third line
            .{ .accept = 1024 }, // 226
            .{ .accept = 1024 }, // 221
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nLIST\r\nQUIT\r\n" },
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
    while (i < 40) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    try testing.expect(std.mem.indexOf(u8, written, "150 Here comes the directory listing\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "226 Directory send OK\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "drwxr-xr-x 1 owner group 0 Jan 01 00:00 docs\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "drwxr-xr-x 1 owner group 0 Jan 01 00:00 pub\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "-rw-r--r-- 1 owner group 123 Jan 01 00:00 readme.txt\r\n") != null);
    try testing.expectEqual(@as(usize, 2), net.closed_listener_len);
    try testing.expectEqual(@as(usize, 2), net.closed_conn_len);
    try testing.expectEqual(@as(u16, 9), net.closed_conn_ids[0]);
    try testing.expectEqual(@as(u16, 1), net.closed_conn_ids[1]);
}

test "server RETR waits for PASV data accept before 150" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .data_accept_script = &.{
            .none,
            .none,
            .{ .conn = 10 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nRETR readme.txt\r\nQUIT\r\n" },
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
    while (i < 6) : (i += 1) {
        try server.tick(0);
    }
    try testing.expect(std.mem.indexOf(u8, net.written(), "150 Opening data connection\r\n") == null);

    while (i < 28) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    const idx_150 = std.mem.indexOf(u8, written, "150 Opening data connection\r\n") orelse return error.UnexpectedTestResult;
    const idx_226 = std.mem.indexOf(u8, written, "226 Closing data connection\r\n") orelse return error.UnexpectedTestResult;
    try testing.expect(idx_150 < idx_226);
}

test "server RETR streams bytes with partial data writes" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .data_accept_script = &.{
            .{ .conn = 11 },
        },
        .write_script = &.{
            .{ .accept = 1024 }, // 220
            .{ .accept = 1024 }, // 331
            .{ .accept = 1024 }, // 230
            .{ .accept = 1024 }, // 227
            .{ .accept = 1024 }, // 150
            .{ .accept = 4 }, // RETR partial
            .would_block,
            .{ .accept = 1024 }, // RETR remainder
            .{ .accept = 1024 }, // 226
            .{ .accept = 1024 }, // 221
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nRETR readme.txt\r\nQUIT\r\n" },
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
    while (i < 40) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    try testing.expect(std.mem.indexOf(u8, written, "150 Opening data connection\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "226 Closing data connection\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "mock-readme-bytes\n") != null);
    try testing.expectEqual(@as(u16, 11), net.closed_conn_ids[0]);
}

test "server maps RETR fs errors to replies" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nRETR missing.bin\r\nPASV\r\nRETR locked.bin\r\nPASV\r\nRETR /docs\r\nQUIT\r\n" },
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
    while (i < 40) : (i += 1) {
        try server.tick(0);
    }

    try testing.expect(std.mem.indexOf(u8, net.written(), "550 File not found\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, net.written(), "550 Permission denied\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, net.written(), "550 Requested action not taken\r\n") != null);
}

test "server STOR waits for PASV data accept before 150" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .data_accept_script = &.{
            .none,
            .none,
            .{ .conn = 12 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nSTOR upload.bin\r\nQUIT\r\n" },
            .{ .bytes = "payload" },
            .closed,
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
    while (i < 6) : (i += 1) {
        try server.tick(0);
    }
    try testing.expect(std.mem.indexOf(u8, net.written(), "150 Opening data connection\r\n") == null);

    while (i < 30) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    const idx_150 = std.mem.indexOf(u8, written, "150 Opening data connection\r\n") orelse return error.UnexpectedTestResult;
    const idx_226 = std.mem.indexOf(u8, written, "226 Closing data connection\r\n") orelse return error.UnexpectedTestResult;
    try testing.expect(idx_150 < idx_226);
}

test "server STOR streams bytes with partial file writes" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .data_accept_script = &.{
            .{ .conn = 13 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nSTOR upload.bin\r\nQUIT\r\n" },
            .{ .bytes = "hello " },
            .would_block,
            .{ .bytes = "world" },
            .eof,
        },
    };
    var fs: MockFs = .{};
    fs.vfs.write_chunk_limit = 3;
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
    while (i < 48) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    try testing.expect(std.mem.indexOf(u8, written, "150 Opening data connection\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "226 Closing data connection\r\n") != null);
    try testing.expect(std.mem.eql(u8, "/upload.bin", fs.vfs.uploaded_path[0..fs.vfs.uploaded_path_len]));
    try testing.expect(std.mem.eql(u8, "hello world", fs.vfs.uploaded_bytes[0..fs.vfs.uploaded_len]));
    try testing.expectEqual(@as(u16, 13), net.closed_conn_ids[0]);
}

test "server maps STOR fs errors to replies" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nPASV\r\nSTOR locked-upload.bin\r\nPASV\r\nSTOR ioerr-upload.bin\r\nPASV\r\nSTOR /docs\r\nQUIT\r\n" },
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
    while (i < 44) : (i += 1) {
        try server.tick(0);
    }

    try testing.expect(std.mem.indexOf(u8, net.written(), "550 Permission denied\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, net.written(), "451 Requested action aborted: local error in processing\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, net.written(), "550 Requested action not taken\r\n") != null);
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

test "server handles DELE RNFR RNTO and optional commands" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nDELE readme.txt\r\nRNFR readme.txt\r\nRNTO moved.txt\r\nMKD newdir\r\nRMD pub/nested\r\nSIZE readme.txt\r\nMDTM readme.txt\r\nQUIT\r\n" },
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
    while (i < 40) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    try testing.expect(std.mem.indexOf(u8, written, "250 Requested file action okay, completed\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "350 Requested file action pending further information\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "257 \"newdir\"\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "213 17\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "213 20240103102030\r\n") != null);
    try testing.expect(std.mem.eql(u8, "/readme.txt", fs.vfs.deleted_path[0..fs.vfs.deleted_path_len]));
    try testing.expect(std.mem.eql(u8, "/readme.txt", fs.vfs.renamed_from_path[0..fs.vfs.renamed_from_len]));
    try testing.expect(std.mem.eql(u8, "/moved.txt", fs.vfs.renamed_to_path[0..fs.vfs.renamed_to_len]));
    try testing.expect(std.mem.eql(u8, "/newdir", fs.vfs.created_dir_path[0..fs.vfs.created_dir_len]));
    try testing.expect(std.mem.eql(u8, "/pub/nested", fs.vfs.removed_dir_path[0..fs.vfs.removed_dir_len]));
}

test "server enforces strict RNFR RNTO sequencing" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nRNFR readme.txt\r\nNOOP\r\nRNTO moved.txt\r\nQUIT\r\n" },
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
    while (i < 24) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    const idx_350 = std.mem.indexOf(u8, written, "350 Requested file action pending further information\r\n") orelse return error.UnexpectedTestResult;
    const idx_503 = std.mem.indexOf(u8, written, "503 Bad sequence of commands\r\n") orelse return error.UnexpectedTestResult;
    const idx_250 = std.mem.lastIndexOf(u8, written, "250 Requested file action okay, completed\r\n") orelse return error.UnexpectedTestResult;
    try testing.expect(idx_350 < idx_503);
    try testing.expect(idx_503 < idx_250);
}

test "server maps milestone 11 fs errors to replies" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nDELE missing.bin\r\nDELE bad\x00name\r\nRNFR ioerr.bin\r\nRNTO moved.bin\r\nMKD locked-new\r\nRMD missing\r\nSIZE /docs\r\nMDTM missing.bin\r\nRNTO moved.bin\r\nQUIT\r\n" },
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
    while (i < 56) : (i += 1) {
        try server.tick(0);
    }

    const written = net.written();
    try testing.expect(std.mem.indexOf(u8, written, "550 File not found\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "553 Requested action not taken. File name not allowed\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "451 Requested action aborted: local error in processing\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "550 Permission denied\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "550 Requested action not taken\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, written, "503 Bad sequence of commands\r\n") != null);
}

test "server TYPE A returns matching reply text" {
    var net: mock_net.MockNet = .{
        .control_accept_script = &.{
            .{ .conn = 1 },
        },
        .read_script = &.{
            .{ .bytes = "USER test\r\nPASS secret\r\nTYPE A\r\nQUIT\r\n" },
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
    while (i < 16) : (i += 1) {
        try server.tick(0);
    }

    try testing.expect(std.mem.indexOf(u8, net.written(), "200 Type set to A\r\n") != null);
}
