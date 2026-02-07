const std = @import("std");
const ftp = @import("ftp_server");
const interfaces_fs = ftp.interfaces_fs;

const max_path_len = std.fs.max_path_bytes;

/// std.fs-backed VFS rooted at a fixed directory.
pub const VfsOs = struct {
    io: std.Io,
    root_dir: std.Io.Dir,

    pub const Cwd = struct {
        path: [max_path_len]u8 = [_]u8{0} ** max_path_len,
        len: usize = 1,
    };

    pub const FileReader = struct {};
    pub const FileWriter = struct {};
    pub const DirIter = struct {};

    pub fn init(io: std.Io, root_path: []const u8) !VfsOs {
        var dir = try std.Io.Dir.cwd().openDir(io, root_path, .{});
        errdefer dir.close(io);
        return .{ .io = io, .root_dir = dir };
    }

    pub fn deinit(self: *VfsOs) void {
        self.root_dir.close(self.io);
    }

    pub fn cwdInit(_: *VfsOs) interfaces_fs.FsError!Cwd {
        var cwd: Cwd = .{};
        cwd.path[0] = '/';
        cwd.len = 1;
        return cwd;
    }

    pub fn cwdPwd(_: *VfsOs, cwd: *const Cwd, out: []u8) interfaces_fs.FsError![]const u8 {
        if (out.len < cwd.len) return error.InvalidPath;
        std.mem.copyForwards(u8, out[0..cwd.len], cwd.path[0..cwd.len]);
        return out[0..cwd.len];
    }

    pub fn cwdChange(self: *VfsOs, cwd: *Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        var next_path: [max_path_len]u8 = undefined;
        const normalized = try normalizePath(cwd, user_path, next_path[0..]);

        var rel_buf: [max_path_len]u8 = undefined;
        const rel_path = try toRelative(normalized, rel_buf[0..]);
        var dir = self.root_dir.openDir(self.io, rel_path, .{}) catch |err| return mapFsError(err);
        dir.close(self.io);

        std.mem.copyForwards(u8, cwd.path[0..normalized.len], normalized);
        cwd.len = normalized.len;
    }

    pub fn cwdUp(self: *VfsOs, cwd: *Cwd) interfaces_fs.FsError!void {
        try self.cwdChange(cwd, "..");
    }

    pub fn dirOpen(_: *VfsOs, _: *const Cwd, _: ?[]const u8) interfaces_fs.FsError!DirIter {
        return error.Unsupported;
    }

    pub fn dirNext(_: *VfsOs, _: *DirIter) interfaces_fs.FsError!?interfaces_fs.DirEntry {
        return error.Unsupported;
    }

    pub fn dirClose(_: *VfsOs, _: *DirIter) void {}

    pub fn openRead(_: *VfsOs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!FileReader {
        return error.Unsupported;
    }

    pub fn openWriteTrunc(_: *VfsOs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!FileWriter {
        return error.Unsupported;
    }

    pub fn readFile(_: *VfsOs, _: *FileReader, _: []u8) interfaces_fs.FsError!usize {
        return error.Unsupported;
    }

    pub fn writeFile(_: *VfsOs, _: *FileWriter, _: []const u8) interfaces_fs.FsError!usize {
        return error.Unsupported;
    }

    pub fn closeRead(_: *VfsOs, _: *FileReader) void {}

    pub fn closeWrite(_: *VfsOs, _: *FileWriter) void {}

    pub fn delete(_: *VfsOs, _: *const Cwd, _: []const u8) interfaces_fs.FsError!void {
        return error.Unsupported;
    }

    pub fn rename(_: *VfsOs, _: *const Cwd, _: []const u8, _: []const u8) interfaces_fs.FsError!void {
        return error.Unsupported;
    }
};

fn normalizePath(cwd: *const VfsOs.Cwd, user_path: []const u8, out: []u8) interfaces_fs.FsError![]const u8 {
    if (user_path.len == 0) return error.InvalidPath;
    if (std.mem.indexOfScalar(u8, user_path, 0) != null) return error.InvalidPath;

    var next_len: usize = 0;
    if (user_path[0] == '/') {
        out[0] = '/';
        next_len = 1;
    } else {
        if (cwd.len > out.len) return error.InvalidPath;
        std.mem.copyForwards(u8, out[0..cwd.len], cwd.path[0..cwd.len]);
        next_len = cwd.len;
    }

    var i: usize = 0;
    while (i < user_path.len) {
        while (i < user_path.len and user_path[i] == '/') : (i += 1) {}
        if (i >= user_path.len) break;

        const start = i;
        while (i < user_path.len and user_path[i] != '/') : (i += 1) {}
        const segment = user_path[start..i];

        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) continue;
        if (std.mem.eql(u8, segment, "..")) {
            if (next_len > 1) {
                var back = next_len - 1;
                while (back > 0 and out[back] != '/') : (back -= 1) {}
                next_len = if (back == 0) 1 else back;
            }
            continue;
        }

        if (std.mem.indexOfScalar(u8, segment, 0) != null) return error.InvalidPath;
        if (next_len == 1 and out[0] == '/') {
            if (next_len + segment.len > out.len) return error.InvalidPath;
            std.mem.copyForwards(u8, out[next_len .. next_len + segment.len], segment);
            next_len += segment.len;
        } else {
            if (next_len + 1 + segment.len > out.len) return error.InvalidPath;
            out[next_len] = '/';
            next_len += 1;
            std.mem.copyForwards(u8, out[next_len .. next_len + segment.len], segment);
            next_len += segment.len;
        }
    }

    if (next_len == 0) {
        out[0] = '/';
        next_len = 1;
    }
    return out[0..next_len];
}

fn toRelative(abs_path: []const u8, out: []u8) interfaces_fs.FsError![]const u8 {
    if (abs_path.len == 0 or abs_path[0] != '/') return error.InvalidPath;
    if (abs_path.len == 1) return ".";
    const rel = abs_path[1..];
    if (rel.len > out.len) return error.InvalidPath;
    std.mem.copyForwards(u8, out[0..rel.len], rel);
    return out[0..rel.len];
}

fn mapFsError(err: anyerror) interfaces_fs.FsError {
    return switch (err) {
        error.FileNotFound => error.NotFound,
        error.NotDir => error.NotDir,
        error.IsDir => error.IsDir,
        error.AccessDenied => error.PermissionDenied,
        error.ReadOnlyFileSystem => error.ReadOnly,
        error.PathAlreadyExists => error.Exists,
        error.NoSpaceLeft => error.NoSpace,
        error.BadPathName,
        error.InvalidUtf8,
        error.NameTooLong,
        error.SymLinkLoop,
        error.InvalidHandle,
        error.FileBusy,
        => error.InvalidPath,
        error.OperationNotSupported => error.Unsupported,
        else => error.Io,
    };
}
