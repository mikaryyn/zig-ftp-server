const std = @import("std");
const net = std.Io.net;
const net_std = @import("net_std.zig");

/// Banner sent immediately after accepting a control connection.
const banner = "220 FTP Server Ready\r\n";

/// Entry point for the minimal CLI harness.
pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var args_it = try init.minimal.args.iterateAllocator(gpa);
    defer args_it.deinit();

    _ = args_it.next();
    var listen_addr: []const u8 = "127.0.0.1:2121";
    while (args_it.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--listen")) {
            const next = args_it.next() orelse {
                try usageAndExit();
            };
            listen_addr = next[0..next.len];
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
    var listener = try net_impl.controlListen(address);
    defer net_impl.closeListener(&listener);

    std.log.info("Listening on {s}", .{listen_addr});

    if (try net_impl.acceptControl(&listener)) |*conn| {
        defer net_impl.closeConn(conn);
        _ = try net_impl.write(conn, banner);
    }
}

/// Print usage information and exit with an error.
fn usageAndExit() !noreturn {
    std.debug.print(
        "Usage: ftp-server --listen <ip:port>\n" ++
            "Example: ftp-server --listen 127.0.0.1:2121\n",
        .{},
    );
    return error.InvalidArgs;
}
