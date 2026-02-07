const std = @import("std");

pub const limits = @import("ftp/limits.zig");
pub const interfaces_net = @import("ftp/interfaces_net.zig");
pub const interfaces_fs = @import("ftp/interfaces_fs.zig");

pub const Buffers = struct {
    command_len: usize = limits.command_max,
    reply_len: usize = limits.reply_max,
    transfer_len: usize = limits.transfer_max,
    scratch_len: usize = limits.scratch_max,
};

pub const Timeouts = struct {
    control_idle_ms: ?u64 = null,
    pasv_idle_ms: ?u64 = null,
    transfer_idle_ms: ?u64 = null,
};

pub const Config = struct {
    user: []const u8,
    password: []const u8,
    banner: []const u8 = "FTP Server Ready",
    buffers: Buffers = .{},
    timeouts: ?Timeouts = null,
};

pub const Session = struct {
    _reserved: u8 = 0,
};

pub const Storage = struct {
    session: Session = .{},
    command_buf: []u8,
    reply_buf: []u8,
    transfer_buf: []u8,
    scratch: []u8,

    pub fn init(command_buf: []u8, reply_buf: []u8, transfer_buf: []u8, scratch: []u8) Storage {
        return .{
            .command_buf = command_buf,
            .reply_buf = reply_buf,
            .transfer_buf = transfer_buf,
            .scratch = scratch,
        };
    }
};

pub fn FtpServer(comptime Net: type, comptime Fs: type) type {
    interfaces_net.validate(Net);
    interfaces_fs.validate(Fs);

    return struct {
        const Self = @This();

        net: *Net,
        fs: *Fs,
        config: Config,
        storage: *Storage,

        pub const PasvBindHint = interfaces_net.PasvBindHint(Net.Address);

        pub fn initNoHeap(net: *Net, fs: *Fs, config: Config, storage: *Storage) !Self {
            return .{
                .net = net,
                .fs = fs,
                .config = config,
                .storage = storage,
            };
        }
    };
}

const testing = std.testing;

const MockNet = struct {
    pub const ControlListener = struct {};
    pub const Conn = struct {};
    pub const PasvListener = struct {};
    pub const Address = struct {};

    pub fn controlListen(_: *MockNet, _: Address) interfaces_net.NetError!ControlListener {
        return .{};
    }

    pub fn acceptControl(_: *ControlListener) interfaces_net.NetError!?Conn {
        return null;
    }

    pub fn pasvListen(_: *MockNet, _: interfaces_net.PasvBindHint(Address)) interfaces_net.NetError!PasvListener {
        return .{};
    }

    pub fn pasvLocalAddr(_: *PasvListener) interfaces_net.NetError!Address {
        return .{};
    }

    pub fn acceptData(_: *PasvListener) interfaces_net.NetError!?Conn {
        return null;
    }

    pub fn closeListener(_: *PasvListener) void {}

    pub fn read(_: *Conn, _: []u8) interfaces_net.NetError!usize {
        return 0;
    }

    pub fn write(_: *Conn, _: []const u8) interfaces_net.NetError!usize {
        return 0;
    }

    pub fn closeConn(_: *Conn) void {}

    pub fn localAddr(_: *Conn) interfaces_net.NetError!Address {
        return .{};
    }
};

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

    pub fn makeDir(_: *MockFs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!void {}

    pub fn removeDir(_: *MockFs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!void {}

    pub fn fileSize(_: *MockFs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!u64 {
        return 0;
    }

    pub fn fileMtime(_: *MockFs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!i64 {
        return 0;
    }
};

test "FtpServer initializes with mock interfaces" {
    var cmd_buf: [limits.command_max]u8 = undefined;
    var reply_buf: [limits.reply_max]u8 = undefined;
    var transfer_buf: [limits.transfer_max]u8 = undefined;
    var scratch_buf: [limits.scratch_max]u8 = undefined;

    var storage = Storage.init(cmd_buf[0..], reply_buf[0..], transfer_buf[0..], scratch_buf[0..]);
    var net: MockNet = .{};
    var fs: MockFs = .{};

    const Server = FtpServer(MockNet, MockFs);
    const server = try Server.initNoHeap(&net, &fs, .{
        .user = "user",
        .password = "pass",
    }, &storage);

    _ = server;
    try testing.expect(true);
}
