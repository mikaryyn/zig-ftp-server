/// Error set shared by filesystem implementations.
pub const FsError = error{
    NotFound,
    NotDir,
    IsDir,
    Exists,
    PermissionDenied,
    InvalidPath,
    NoSpace,
    ReadOnly,
    Io,
    Unsupported,
};

/// The kind of path reported by a directory listing entry.
pub const PathKind = enum { file, dir };

/// A single directory entry returned by the filesystem iterator.
pub const DirEntry = struct {
    /// Entry name without path separators.
    name: []const u8,
    /// Whether the entry is a file or directory.
    kind: PathKind,
    /// Optional file size in bytes.
    size: ?u64 = null,
    /// Optional UNIX mtime in seconds.
    mtime_unix: ?i64 = null,
};

/// Compile-time description of the Fs interface.
pub fn FsInterface(comptime Fs: type) type {
    _ = Fs;
    return struct {
        /// Error set alias for Fs implementations.
        pub const Error = FsError;
    };
}

/// Validate that a type satisfies the Fs interface.
pub fn validate(comptime Fs: type) void {
    const missing = struct {
        fn decl(name: []const u8) void {
            @compileError("Fs is missing required declaration: " ++ name);
        }
        fn fnDecl(name: []const u8) void {
            @compileError("Fs is missing required function: " ++ name);
        }
    };

    if (!@hasDecl(Fs, "Cwd")) missing.decl("Cwd");
    if (!@hasDecl(Fs, "FileReader")) missing.decl("FileReader");
    if (!@hasDecl(Fs, "FileWriter")) missing.decl("FileWriter");
    if (!@hasDecl(Fs, "DirIter")) missing.decl("DirIter");

    if (!@hasDecl(Fs, "cwdInit")) missing.fnDecl("cwdInit");
    if (!@hasDecl(Fs, "cwdPwd")) missing.fnDecl("cwdPwd");
    if (!@hasDecl(Fs, "cwdChange")) missing.fnDecl("cwdChange");
    if (!@hasDecl(Fs, "cwdUp")) missing.fnDecl("cwdUp");

    if (!@hasDecl(Fs, "dirOpen")) missing.fnDecl("dirOpen");
    if (!@hasDecl(Fs, "dirNext")) missing.fnDecl("dirNext");
    if (!@hasDecl(Fs, "dirClose")) missing.fnDecl("dirClose");

    if (!@hasDecl(Fs, "openRead")) missing.fnDecl("openRead");
    if (!@hasDecl(Fs, "openWriteTrunc")) missing.fnDecl("openWriteTrunc");
    if (!@hasDecl(Fs, "readFile")) missing.fnDecl("readFile");
    if (!@hasDecl(Fs, "writeFile")) missing.fnDecl("writeFile");
    if (!@hasDecl(Fs, "closeRead")) missing.fnDecl("closeRead");
    if (!@hasDecl(Fs, "closeWrite")) missing.fnDecl("closeWrite");

    if (!@hasDecl(Fs, "delete")) missing.fnDecl("delete");
    if (!@hasDecl(Fs, "rename")) missing.fnDecl("rename");
}
