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

pub const PathKind = enum { file, dir };

pub const DirEntry = struct {
    name: []const u8,
    kind: PathKind,
    size: ?u64 = null,
    mtime_unix: ?i64 = null,
};

pub fn FsInterface(comptime Fs: type) type {
    _ = Fs;
    return struct {
        pub const Error = FsError;
    };
}

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
