const std = @import("std");

/// Supported control-channel commands.
pub const Command = enum {
    user,
    pass,
    quit,
    noop,
    syst,
    type_,
    feat,
    pasv,
    list,
    retr,
    stor,
    pwd,
    cwd,
    cdup,
    dele,
    rnfr,
    rnto,
    mkd,
    rmd,
    size,
    mdtm,
    unknown,
};

/// Parsed FTP command line (`CMD` + optional argument).
pub const Parsed = struct {
    command: Command,
    argument: []const u8,
};

/// Parse one command line without the trailing CRLF.
pub fn parse(line: []const u8) Parsed {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len == 0) {
        return .{ .command = .unknown, .argument = "" };
    }

    const cmd_end = std.mem.indexOfScalar(u8, trimmed, ' ') orelse trimmed.len;
    const cmd_text = trimmed[0..cmd_end];
    const arg_text = std.mem.trim(u8, trimmed[cmd_end..], " ");

    return .{
        .command = parseCommand(cmd_text),
        .argument = arg_text,
    };
}

fn parseCommand(cmd_text: []const u8) Command {
    if (std.ascii.eqlIgnoreCase(cmd_text, "USER")) return .user;
    if (std.ascii.eqlIgnoreCase(cmd_text, "PASS")) return .pass;
    if (std.ascii.eqlIgnoreCase(cmd_text, "QUIT")) return .quit;
    if (std.ascii.eqlIgnoreCase(cmd_text, "NOOP")) return .noop;
    if (std.ascii.eqlIgnoreCase(cmd_text, "SYST")) return .syst;
    if (std.ascii.eqlIgnoreCase(cmd_text, "TYPE")) return .type_;
    if (std.ascii.eqlIgnoreCase(cmd_text, "FEAT")) return .feat;
    if (std.ascii.eqlIgnoreCase(cmd_text, "PASV")) return .pasv;
    if (std.ascii.eqlIgnoreCase(cmd_text, "LIST")) return .list;
    if (std.ascii.eqlIgnoreCase(cmd_text, "RETR")) return .retr;
    if (std.ascii.eqlIgnoreCase(cmd_text, "STOR")) return .stor;
    if (std.ascii.eqlIgnoreCase(cmd_text, "PWD")) return .pwd;
    if (std.ascii.eqlIgnoreCase(cmd_text, "CWD")) return .cwd;
    if (std.ascii.eqlIgnoreCase(cmd_text, "CDUP")) return .cdup;
    if (std.ascii.eqlIgnoreCase(cmd_text, "DELE")) return .dele;
    if (std.ascii.eqlIgnoreCase(cmd_text, "RNFR")) return .rnfr;
    if (std.ascii.eqlIgnoreCase(cmd_text, "RNTO")) return .rnto;
    if (std.ascii.eqlIgnoreCase(cmd_text, "MKD")) return .mkd;
    if (std.ascii.eqlIgnoreCase(cmd_text, "RMD")) return .rmd;
    if (std.ascii.eqlIgnoreCase(cmd_text, "SIZE")) return .size;
    if (std.ascii.eqlIgnoreCase(cmd_text, "MDTM")) return .mdtm;
    return .unknown;
}

const testing = std.testing;

test "parse command and argument" {
    const parsed = parse("USER test");
    try testing.expectEqual(Command.user, parsed.command);
    try testing.expect(std.mem.eql(u8, "test", parsed.argument));
}

test "parse is case insensitive and trims left arg spaces" {
    const parsed = parse("tYpE    I");
    try testing.expectEqual(Command.type_, parsed.command);
    try testing.expect(std.mem.eql(u8, "I", parsed.argument));
}

test "parse unknown for empty line" {
    const parsed = parse("");
    try testing.expectEqual(Command.unknown, parsed.command);
    try testing.expectEqual(@as(usize, 0), parsed.argument.len);
}

test "parse navigation commands" {
    try testing.expectEqual(Command.pwd, parse("PWD").command);
    try testing.expectEqual(Command.cwd, parse("CWD pub").command);
    try testing.expectEqual(Command.cdup, parse("CDUP").command);
}

test "parse pasv and transfer commands" {
    try testing.expectEqual(Command.pasv, parse("PASV").command);
    try testing.expectEqual(Command.list, parse("LIST").command);
    try testing.expectEqual(Command.retr, parse("RETR file.txt").command);
    try testing.expect(std.mem.eql(u8, "file.txt", parse("RETR file.txt").argument));
    try testing.expectEqual(Command.stor, parse("STOR upload.bin").command);
}

test "parse file and optional commands" {
    try testing.expectEqual(Command.dele, parse("DELE old.txt").command);
    try testing.expectEqual(Command.rnfr, parse("RNFR old.txt").command);
    try testing.expectEqual(Command.rnto, parse("RNTO new.txt").command);
    try testing.expectEqual(Command.mkd, parse("MKD pub/newdir").command);
    try testing.expectEqual(Command.rmd, parse("RMD pub/newdir").command);
    try testing.expectEqual(Command.size, parse("SIZE readme.txt").command);
    try testing.expectEqual(Command.mdtm, parse("MDTM readme.txt").command);
}
