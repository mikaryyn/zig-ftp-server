const std = @import("std");
const interfaces_fs = @import("interfaces_fs.zig");

/// Transfer lifecycle used by control and data path coordination.
pub const TransferState = enum {
    idle,
    list_waiting_accept,
    list_streaming,
};

/// Server-side LIST transfer bookkeeping.
pub const ListTransfer = struct {
    state: TransferState = .idle,
    line_len: usize = 0,
    line_off: usize = 0,
    exhausted: bool = false,

    pub fn reset(self: *ListTransfer) void {
        self.* = .{};
    }
};

/// Format one LIST entry line using a deterministic UNIX-like style.
pub fn formatListEntry(out: []u8, entry: interfaces_fs.DirEntry) ![]const u8 {
    const perms = switch (entry.kind) {
        .dir => "drwxr-xr-x",
        .file => "-rw-r--r--",
    };
    const size = entry.size orelse 0;
    return std.fmt.bufPrint(out, "{s} 1 owner group {d} Jan 01 00:00 {s}\r\n", .{
        perms,
        size,
        entry.name,
    });
}

const testing = std.testing;

test "format list entry appends CRLF and stable fields" {
    var buf: [128]u8 = undefined;
    const line = try formatListEntry(buf[0..], .{
        .name = "readme.txt",
        .kind = .file,
        .size = 42,
    });
    try testing.expect(std.mem.eql(u8, "-rw-r--r-- 1 owner group 42 Jan 01 00:00 readme.txt\r\n", line));
}
