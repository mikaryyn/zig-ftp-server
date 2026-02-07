const std = @import("std");
const net = std.Io.net;
const net_std = @import("net_std.zig");
const vfs_os = @import("vfs_os.zig");
const ftp = @import("ftp_server");

/// Entry point for the FTP server CLI harness.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();

    _ = args_it.next();
    var listen_addr: []const u8 = "127.0.0.1:2121";
    var root_path: []const u8 = ".";
    var user: []const u8 = "test";
    var pass: []const u8 = "test";

    while (args_it.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--listen")) {
            const next = args_it.next() orelse {
                try usageAndExit();
            };
            listen_addr = next[0..next.len];
            continue;
        }
        if (std.mem.eql(u8, arg, "--root")) {
            const next = args_it.next() orelse {
                try usageAndExit();
            };
            root_path = next[0..next.len];
            continue;
        }
        if (std.mem.eql(u8, arg, "--user")) {
            const next = args_it.next() orelse {
                try usageAndExit();
            };
            user = next[0..next.len];
            continue;
        }
        if (std.mem.eql(u8, arg, "--pass")) {
            const next = args_it.next() orelse {
                try usageAndExit();
            };
            pass = next[0..next.len];
            continue;
        }
        if (std.mem.eql(u8, arg, "--help")) {
            try usageAndExit();
        }
        std.log.err("Unknown argument: {s}", .{arg});
        try usageAndExit();
    }

    const address = net.IpAddress.parseLiteral(listen_addr) catch |err| {
        std.log.err("Invalid listen address '{s}': {s}", .{ listen_addr, @errorName(err) });
        return err;
    };

    var net_impl: net_std.NetStd = .{ .io = init.io };
    var fs_impl = try vfs_os.VfsOs.init(init.io, root_path);
    defer fs_impl.deinit();

    var listener = try net_impl.controlListen(address);
    defer net_impl.closeControlListener(&listener);

    var command_buf: [ftp.limits.command_max]u8 = undefined;
    var reply_buf: [ftp.limits.reply_max]u8 = undefined;
    var transfer_buf: [ftp.limits.transfer_max]u8 = undefined;
    var scratch_buf: [ftp.limits.scratch_max]u8 = undefined;
    var storage = ftp.misc.Storage.init(
        command_buf[0..],
        reply_buf[0..],
        transfer_buf[0..],
        scratch_buf[0..],
    );
    var timer = std.time.Timer.start() catch return error.TimerUnsupported;

    const Server = ftp.server.FtpServer(net_std.NetStd, vfs_os.VfsOs);
    var server = Server.initNoHeap(&net_impl, &fs_impl, listener, .{
        .user = user,
        .password = pass,
        .banner = "FTP Server Ready",
    }, &storage);

    std.log.info("Listening on {s} (root={s}, user={s})", .{ listen_addr, root_path, user });

    while (true) {
        const now_ms: u64 = timer.read() / std.time.ns_per_ms;

        server.tick(now_ms) catch |err| switch (err) {
            error.WouldBlock => {},
            else => {
                std.log.err("server tick failed: {s}", .{@errorName(err)});
                return err;
            },
        };
    }
}

/// Print usage information and exit with an error.
fn usageAndExit() !noreturn {
    std.debug.print(
        "Usage: ftp-server [--listen <ip:port>] [--root <path>] [--user <name>] [--pass <pass>]\n" ++
            "Example: ftp-server --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test\n",
        .{},
    );
    return error.InvalidArgs;
}
