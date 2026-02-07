const std = @import("std");
const limits = @import("limits.zig");
const interfaces_net = @import("interfaces_net.zig");
const interfaces_fs = @import("interfaces_fs.zig");

/// Size configuration for the core buffers.
pub const Buffers = struct {
    /// Maximum command line length buffer.
    command_len: usize = limits.command_max,
    /// Maximum reply line length buffer.
    reply_len: usize = limits.reply_max,
    /// Transfer streaming buffer length.
    transfer_len: usize = limits.transfer_max,
    /// Scratch buffer length for parsing/formatting.
    scratch_len: usize = limits.scratch_max,
};

/// Optional timeout configuration for control and data paths.
pub const Timeouts = struct {
    /// Optional idle timeout for the control connection.
    control_idle_ms: ?u64 = null,
    /// Optional idle timeout while waiting for PASV data connections.
    pasv_idle_ms: ?u64 = null,
    /// Optional idle timeout during transfers.
    transfer_idle_ms: ?u64 = null,
};

/// Server configuration for the single-session core.
pub const Config = struct {
    /// Username required for login.
    user: []const u8,
    /// Password required for login.
    password: []const u8,
    /// Human-readable banner text.
    banner: []const u8 = "FTP Server Ready",
    /// Buffer sizing configuration.
    buffers: Buffers = .{},
    /// Optional timeout configuration.
    timeouts: ?Timeouts = null,
};

/// Opaque placeholder for the session state (populated in later milestones).
pub const Session = struct {
    /// Reserved for future session state.
    _reserved: u8 = 0,
};

/// Caller-owned storage for the core buffers and session state.
pub const Storage = struct {
    /// Single-session state storage.
    session: Session = .{},
    /// Command line buffer storage.
    command_buf: []u8,
    /// Reply line buffer storage.
    reply_buf: []u8,
    /// Data transfer buffer storage.
    transfer_buf: []u8,
    /// Scratch buffer storage.
    scratch: []u8,

    /// Initialize storage with preallocated buffers.
    pub fn init(command_buf: []u8, reply_buf: []u8, transfer_buf: []u8, scratch: []u8) Storage {
        return .{
            .command_buf = command_buf,
            .reply_buf = reply_buf,
            .transfer_buf = transfer_buf,
            .scratch = scratch,
        };
    }
};

/// Instantiate the FTP server core for a given Net and Fs implementation.
pub fn FtpServer(comptime Net: type, comptime Fs: type) type {
    interfaces_net.validate(Net);
    interfaces_fs.validate(Fs);

    return struct {
        const Self = @This();

        /// Net implementation backing the server.
        net: *Net,
        /// Fs implementation backing the server.
        fs: *Fs,
        /// Server configuration (credentials, banner, buffers).
        config: Config,
        /// Caller-owned storage for session state and buffers.
        storage: *Storage,

        /// Type alias for the passive bind hint derived from the Net address type.
        pub const PasvBindHint = interfaces_net.PasvBindHint(Net.Address);

        /// Initialize the server with caller-owned storage and no heap allocation.
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

/// Testing utilities for the module tests.
const testing = std.testing;

/// Minimal Net mock for compile-time interface validation.
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

/// Minimal Fs mock for compile-time interface validation.
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
