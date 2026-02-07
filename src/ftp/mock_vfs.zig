const std = @import("std");
const interfaces_fs = @import("interfaces_fs.zig");

/// In-memory mock filesystem focused on CWD/PWD behavior.
pub const MockVfs = struct {
    uploaded_path: [128]u8 = [_]u8{0} ** 128,
    uploaded_path_len: usize = 0,
    uploaded_bytes: [1024]u8 = [_]u8{0} ** 1024,
    uploaded_len: usize = 0,
    write_chunk_limit: usize = std.math.maxInt(usize),
    deleted_path: [128]u8 = [_]u8{0} ** 128,
    deleted_path_len: usize = 0,
    renamed_from_path: [128]u8 = [_]u8{0} ** 128,
    renamed_from_len: usize = 0,
    renamed_to_path: [128]u8 = [_]u8{0} ** 128,
    renamed_to_len: usize = 0,
    created_dir_path: [128]u8 = [_]u8{0} ** 128,
    created_dir_len: usize = 0,
    removed_dir_path: [128]u8 = [_]u8{0} ** 128,
    removed_dir_len: usize = 0,

    /// Current working directory state represented as an absolute path.
    pub const Cwd = struct {
        path: [128]u8 = [_]u8{0} ** 128,
        len: usize = 1,

        pub fn asSlice(self: *const Cwd) []const u8 {
            return self.path[0..self.len];
        }
    };

    pub const FileReader = struct {
        bytes: []const u8 = "",
        off: usize = 0,
    };
    pub const FileWriter = struct {};
    pub const DirIter = struct {
        entries: []const interfaces_fs.DirEntry = &.{},
        index: usize = 0,
    };

    /// Initialize to root (`/`).
    pub fn cwdInit(_: *MockVfs) interfaces_fs.FsError!Cwd {
        var cwd: Cwd = .{};
        cwd.path[0] = '/';
        cwd.len = 1;
        return cwd;
    }

    /// Copy the current path to `out`.
    pub fn cwdPwd(_: *MockVfs, cwd: *const Cwd, out: []u8) interfaces_fs.FsError![]const u8 {
        if (out.len < cwd.len) return error.InvalidPath;
        std.mem.copyForwards(u8, out[0..cwd.len], cwd.path[0..cwd.len]);
        return out[0..cwd.len];
    }

    /// Change to `user_path` (absolute or relative).
    pub fn cwdChange(_: *MockVfs, cwd: *Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        if (user_path.len == 0) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, user_path, 0) != null) return error.InvalidPath;

        if (std.mem.eql(u8, user_path, "locked") or std.mem.eql(u8, user_path, "/locked")) {
            return error.PermissionDenied;
        }
        if (std.mem.eql(u8, user_path, "ioerr") or std.mem.eql(u8, user_path, "/ioerr")) {
            return error.Io;
        }

        var next_path: [128]u8 = [_]u8{0} ** 128;
        var next_len: usize = 0;

        if (user_path[0] == '/') {
            next_path[0] = '/';
            next_len = 1;
        } else {
            std.mem.copyForwards(u8, next_path[0..cwd.len], cwd.path[0..cwd.len]);
            next_len = cwd.len;
        }

        var i: usize = 0;
        while (i < user_path.len) {
            while (i < user_path.len and user_path[i] == '/') : (i += 1) {}
            if (i >= user_path.len) break;
            const start = i;
            while (i < user_path.len and user_path[i] != '/') : (i += 1) {}
            const segment = user_path[start..i];

            if (std.mem.eql(u8, segment, ".")) continue;
            if (std.mem.eql(u8, segment, "..")) {
                if (next_len > 1) {
                    var back = next_len - 1;
                    while (back > 0 and next_path[back] != '/') : (back -= 1) {}
                    next_len = if (back == 0) 1 else back;
                }
                continue;
            }

            if (std.mem.indexOfScalar(u8, segment, 0) != null) return error.InvalidPath;
            if (segment.len == 0) continue;

            if (next_len == 1 and next_path[0] == '/') {
                if (next_len + segment.len > next_path.len) return error.InvalidPath;
                std.mem.copyForwards(u8, next_path[next_len .. next_len + segment.len], segment);
                next_len += segment.len;
            } else {
                if (next_len + 1 + segment.len > next_path.len) return error.InvalidPath;
                next_path[next_len] = '/';
                next_len += 1;
                std.mem.copyForwards(u8, next_path[next_len .. next_len + segment.len], segment);
                next_len += segment.len;
            }
        }

        const normalized = next_path[0..next_len];
        if (!isKnownDir(normalized)) {
            if (isKnownFile(normalized)) return error.NotDir;
            return error.NotFound;
        }

        std.mem.copyForwards(u8, cwd.path[0..next_len], normalized);
        cwd.len = next_len;
    }

    /// Move one level up while staying rooted.
    pub fn cwdUp(self: *MockVfs, cwd: *Cwd) interfaces_fs.FsError!void {
        try self.cwdChange(cwd, "..");
    }

    pub fn dirOpen(self: *MockVfs, cwd: *const Cwd, path: ?[]const u8) interfaces_fs.FsError!DirIter {
        var path_buf: [128]u8 = undefined;
        const target = try self.resolveDirPath(cwd, path, path_buf[0..]);
        const entries = entriesFor(target) orelse {
            if (isKnownFile(target)) return error.NotDir;
            return error.NotFound;
        };
        return .{
            .entries = entries,
        };
    }

    pub fn dirNext(_: *MockVfs, iter: *DirIter) interfaces_fs.FsError!?interfaces_fs.DirEntry {
        if (iter.index >= iter.entries.len) return null;
        const entry = iter.entries[iter.index];
        iter.index += 1;
        return entry;
    }

    pub fn dirClose(_: *MockVfs, _: *DirIter) void {}

    pub fn openRead(_: *MockVfs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!FileReader {
        var path_buf: [128]u8 = undefined;
        const path = try resolveFilePath(cwd, user_path, path_buf[0..]);
        if (std.mem.eql(u8, path, "/missing.bin")) return error.NotFound;
        if (std.mem.eql(u8, path, "/locked.bin")) return error.PermissionDenied;
        if (isKnownDir(path)) return error.IsDir;

        if (std.mem.eql(u8, path, "/readme.txt")) {
            return .{ .bytes = readme_bytes[0..] };
        }
        if (std.mem.eql(u8, path, "/pub/upload.txt")) {
            return .{ .bytes = upload_bytes[0..] };
        }
        return error.NotFound;
    }

    pub fn openWriteTrunc(self: *MockVfs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!FileWriter {
        var path_buf: [128]u8 = undefined;
        const path = try resolveFilePath(cwd, user_path, path_buf[0..]);

        if (std.mem.eql(u8, path, "/locked-upload.bin")) return error.PermissionDenied;
        if (std.mem.eql(u8, path, "/ioerr-upload.bin")) return error.Io;
        if (isKnownDir(path)) return error.IsDir;

        if (path.len > self.uploaded_path.len) return error.InvalidPath;
        std.mem.copyForwards(u8, self.uploaded_path[0..path.len], path);
        self.uploaded_path_len = path.len;
        self.uploaded_len = 0;
        return .{};
    }

    pub fn readFile(_: *MockVfs, reader: *FileReader, out: []u8) interfaces_fs.FsError!usize {
        if (reader.off >= reader.bytes.len) return 0;
        const remaining = reader.bytes.len - reader.off;
        const n = @min(remaining, out.len);
        std.mem.copyForwards(u8, out[0..n], reader.bytes[reader.off .. reader.off + n]);
        reader.off += n;
        return n;
    }

    pub fn writeFile(self: *MockVfs, _: *FileWriter, src: []const u8) interfaces_fs.FsError!usize {
        if (src.len == 0) return 0;
        if (self.uploaded_len >= self.uploaded_bytes.len) return error.NoSpace;

        const remaining = self.uploaded_bytes.len - self.uploaded_len;
        const n = @min(@min(src.len, remaining), self.write_chunk_limit);
        if (n == 0) return error.NoSpace;

        std.mem.copyForwards(u8, self.uploaded_bytes[self.uploaded_len .. self.uploaded_len + n], src[0..n]);
        self.uploaded_len += n;
        return n;
    }

    pub fn closeRead(_: *MockVfs, _: *FileReader) void {}

    pub fn closeWrite(_: *MockVfs, _: *FileWriter) void {}

    pub fn delete(self: *MockVfs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        var path_buf: [128]u8 = undefined;
        const path = try resolveFilePath(cwd, user_path, path_buf[0..]);

        if (std.mem.eql(u8, path, "/missing.bin")) return error.NotFound;
        if (std.mem.eql(u8, path, "/locked.bin")) return error.PermissionDenied;
        if (std.mem.eql(u8, path, "/ioerr.bin")) return error.Io;
        if (isKnownDir(path)) return error.IsDir;

        if (path.len > self.deleted_path.len) return error.InvalidPath;
        std.mem.copyForwards(u8, self.deleted_path[0..path.len], path);
        self.deleted_path_len = path.len;
    }

    pub fn rename(self: *MockVfs, cwd: *const Cwd, from_path: []const u8, to_path: []const u8) interfaces_fs.FsError!void {
        var from_buf: [128]u8 = undefined;
        var to_buf: [128]u8 = undefined;
        const from = try resolveFilePath(cwd, from_path, from_buf[0..]);
        const to = try resolveFilePath(cwd, to_path, to_buf[0..]);

        if (std.mem.eql(u8, from, "/missing.bin")) return error.NotFound;
        if (std.mem.eql(u8, from, "/locked.bin")) return error.PermissionDenied;
        if (std.mem.eql(u8, from, "/ioerr.bin")) return error.Io;
        if (std.mem.eql(u8, to, "/readme.txt")) return error.Exists;

        if (from.len > self.renamed_from_path.len or to.len > self.renamed_to_path.len) return error.InvalidPath;
        std.mem.copyForwards(u8, self.renamed_from_path[0..from.len], from);
        self.renamed_from_len = from.len;
        std.mem.copyForwards(u8, self.renamed_to_path[0..to.len], to);
        self.renamed_to_len = to.len;
    }

    pub fn makeDir(self: *MockVfs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        var path_buf: [128]u8 = undefined;
        const path = try resolveFilePath(cwd, user_path, path_buf[0..]);

        if (std.mem.eql(u8, path, "/locked-new")) return error.PermissionDenied;
        if (std.mem.eql(u8, path, "/ioerr-new")) return error.Io;
        if (isKnownDir(path) or isKnownFile(path)) return error.Exists;

        if (path.len > self.created_dir_path.len) return error.InvalidPath;
        std.mem.copyForwards(u8, self.created_dir_path[0..path.len], path);
        self.created_dir_len = path.len;
    }

    pub fn removeDir(self: *MockVfs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!void {
        var path_buf: [128]u8 = undefined;
        const path = try resolveFilePath(cwd, user_path, path_buf[0..]);

        if (std.mem.eql(u8, path, "/locked")) return error.PermissionDenied;
        if (std.mem.eql(u8, path, "/ioerr")) return error.Io;
        if (std.mem.eql(u8, path, "/missing")) return error.NotFound;
        if (isKnownFile(path)) return error.NotDir;

        if (path.len > self.removed_dir_path.len) return error.InvalidPath;
        std.mem.copyForwards(u8, self.removed_dir_path[0..path.len], path);
        self.removed_dir_len = path.len;
    }

    pub fn fileSize(_: *MockVfs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!u64 {
        var path_buf: [128]u8 = undefined;
        const path = try resolveFilePath(cwd, user_path, path_buf[0..]);
        if (std.mem.eql(u8, path, "/missing.bin")) return error.NotFound;
        if (std.mem.eql(u8, path, "/locked.bin")) return error.PermissionDenied;
        if (std.mem.eql(u8, path, "/ioerr.bin")) return error.Io;
        if (isKnownDir(path)) return error.IsDir;

        if (std.mem.eql(u8, path, "/readme.txt")) return readme_bytes.len;
        if (std.mem.eql(u8, path, "/pub/upload.txt")) return upload_bytes.len;
        return 42;
    }

    pub fn fileMtime(_: *MockVfs, cwd: *const Cwd, user_path: []const u8) interfaces_fs.FsError!i64 {
        var path_buf: [128]u8 = undefined;
        const path = try resolveFilePath(cwd, user_path, path_buf[0..]);
        if (std.mem.eql(u8, path, "/missing.bin")) return error.NotFound;
        if (std.mem.eql(u8, path, "/locked.bin")) return error.PermissionDenied;
        if (std.mem.eql(u8, path, "/ioerr.bin")) return error.Io;
        if (isKnownDir(path)) return error.IsDir;

        if (std.mem.eql(u8, path, "/readme.txt")) return 1_704_067_230; // 2024-01-03 10:20:30 UTC
        return 1_704_067_231;
    }

    fn isKnownDir(path: []const u8) bool {
        return std.mem.eql(u8, path, "/") or
            std.mem.eql(u8, path, "/pub") or
            std.mem.eql(u8, path, "/pub/nested") or
            std.mem.eql(u8, path, "/docs");
    }

    fn isKnownFile(path: []const u8) bool {
        return std.mem.eql(u8, path, "/readme.txt");
    }

    fn resolveDirPath(self: *MockVfs, cwd: *const Cwd, path: ?[]const u8, out: []u8) interfaces_fs.FsError![]const u8 {
        if (path) |raw| {
            if (raw.len == 0) return cwd.asSlice();
            var temp = cwd.*;
            try self.cwdChange(&temp, raw);
            if (temp.len > out.len) return error.InvalidPath;
            std.mem.copyForwards(u8, out[0..temp.len], temp.path[0..temp.len]);
            return out[0..temp.len];
        }
        if (cwd.len > out.len) return error.InvalidPath;
        std.mem.copyForwards(u8, out[0..cwd.len], cwd.path[0..cwd.len]);
        return out[0..cwd.len];
    }

    fn resolveFilePath(cwd: *const Cwd, user_path: []const u8, out: []u8) interfaces_fs.FsError![]const u8 {
        if (user_path.len == 0) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, user_path, 0) != null) return error.InvalidPath;

        if (user_path[0] == '/') {
            if (user_path.len > out.len) return error.InvalidPath;
            std.mem.copyForwards(u8, out[0..user_path.len], user_path);
            return out[0..user_path.len];
        }

        if (cwd.len == 1 and cwd.path[0] == '/') {
            return std.fmt.bufPrint(out, "/{s}", .{user_path}) catch error.InvalidPath;
        }
        return std.fmt.bufPrint(out, "{s}/{s}", .{ cwd.asSlice(), user_path }) catch error.InvalidPath;
    }

    fn entriesFor(path: []const u8) ?[]const interfaces_fs.DirEntry {
        if (std.mem.eql(u8, path, "/")) return root_entries[0..];
        if (std.mem.eql(u8, path, "/pub")) return pub_entries[0..];
        if (std.mem.eql(u8, path, "/docs")) return docs_entries[0..];
        if (std.mem.eql(u8, path, "/pub/nested")) return nested_entries[0..];
        return null;
    }

    const root_entries = [_]interfaces_fs.DirEntry{
        .{ .name = "docs", .kind = .dir },
        .{ .name = "pub", .kind = .dir },
        .{ .name = "readme.txt", .kind = .file, .size = 123 },
    };
    const pub_entries = [_]interfaces_fs.DirEntry{
        .{ .name = "nested", .kind = .dir },
        .{ .name = "upload.txt", .kind = .file, .size = 17 },
    };
    const docs_entries = [_]interfaces_fs.DirEntry{
        .{ .name = "guide.md", .kind = .file, .size = 64 },
    };
    const nested_entries = [_]interfaces_fs.DirEntry{};
    const readme_bytes = "mock-readme-bytes\n";
    const upload_bytes = "uploaded-through-mock\n";
};

const testing = std.testing;

test "mock vfs resolves cwd transitions" {
    var vfs: MockVfs = .{};
    var cwd = try vfs.cwdInit();

    try vfs.cwdChange(&cwd, "pub");
    try testing.expect(std.mem.eql(u8, "/pub", cwd.asSlice()));

    try vfs.cwdChange(&cwd, "nested");
    try testing.expect(std.mem.eql(u8, "/pub/nested", cwd.asSlice()));

    try vfs.cwdUp(&cwd);
    try testing.expect(std.mem.eql(u8, "/pub", cwd.asSlice()));

    try vfs.cwdChange(&cwd, "/docs");
    try testing.expect(std.mem.eql(u8, "/docs", cwd.asSlice()));
}

test "mock vfs reports known navigation errors" {
    var vfs: MockVfs = .{};
    var cwd = try vfs.cwdInit();

    try testing.expectError(error.NotFound, vfs.cwdChange(&cwd, "missing"));
    try testing.expectError(error.NotDir, vfs.cwdChange(&cwd, "/readme.txt"));
    try testing.expectError(error.PermissionDenied, vfs.cwdChange(&cwd, "locked"));
    try testing.expectError(error.Io, vfs.cwdChange(&cwd, "ioerr"));
}

test "mock vfs directory iterator returns deterministic entries" {
    var vfs: MockVfs = .{};
    var cwd = try vfs.cwdInit();

    var iter = try vfs.dirOpen(&cwd, null);
    defer vfs.dirClose(&iter);

    const first = (try vfs.dirNext(&iter)).?;
    try testing.expect(std.mem.eql(u8, "docs", first.name));
    try testing.expectEqual(interfaces_fs.PathKind.dir, first.kind);

    const second = (try vfs.dirNext(&iter)).?;
    try testing.expect(std.mem.eql(u8, "pub", second.name));

    const third = (try vfs.dirNext(&iter)).?;
    try testing.expect(std.mem.eql(u8, "readme.txt", third.name));
    try testing.expectEqual(@as(?u64, 123), third.size);

    try testing.expectEqual(@as(?interfaces_fs.DirEntry, null), try vfs.dirNext(&iter));
}

test "mock vfs openRead streams deterministic file bytes" {
    var vfs: MockVfs = .{};
    var cwd = try vfs.cwdInit();

    var reader = try vfs.openRead(&cwd, "readme.txt");
    defer vfs.closeRead(&reader);

    var buf: [64]u8 = undefined;
    const n1 = try vfs.readFile(&reader, buf[0..4]);
    try testing.expectEqual(@as(usize, 4), n1);
    const n2 = try vfs.readFile(&reader, buf[n1..]);
    try testing.expect(std.mem.eql(u8, "mock-readme-bytes\n", buf[0 .. n1 + n2]));

    try testing.expectEqual(@as(usize, 0), try vfs.readFile(&reader, buf[0..]));
}

test "mock vfs openWriteTrunc and writeFile capture uploaded bytes" {
    var vfs: MockVfs = .{};
    var cwd = try vfs.cwdInit();

    var writer = try vfs.openWriteTrunc(&cwd, "upload.bin");
    defer vfs.closeWrite(&writer);

    try testing.expectEqual(@as(usize, 6), try vfs.writeFile(&writer, "hello "));
    try testing.expectEqual(@as(usize, 5), try vfs.writeFile(&writer, "world"));

    try testing.expect(std.mem.eql(u8, "/upload.bin", vfs.uploaded_path[0..vfs.uploaded_path_len]));
    try testing.expect(std.mem.eql(u8, "hello world", vfs.uploaded_bytes[0..vfs.uploaded_len]));
}
