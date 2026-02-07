/// Error set shared by network implementations.
pub const NetError = error{
    WouldBlock,
    Closed,
    Timeout,
    AddrUnavailable,
    Io,
};

/// Passive-mode bind hint supplied by the core when opening a data listener.
pub fn PasvBindHint(comptime Address: type) type {
    return struct {
        /// Optional local control address for binding the PASV listener.
        control_local: ?Address = null,
    };
}

/// Compile-time description of the Net interface.
pub fn NetInterface(comptime Net: type) type {
    _ = Net;
    return struct {
        /// Error set alias for Net implementations.
        pub const Error = NetError;
    };
}

/// Validate that a type satisfies the Net interface.
pub fn validate(comptime Net: type) void {
    const missing = struct {
        fn decl(name: []const u8) void {
            @compileError("Net is missing required declaration: " ++ name);
        }
        fn fnDecl(name: []const u8) void {
            @compileError("Net is missing required function: " ++ name);
        }
    };

    if (!@hasDecl(Net, "ControlListener")) missing.decl("ControlListener");
    if (!@hasDecl(Net, "Conn")) missing.decl("Conn");
    if (!@hasDecl(Net, "PasvListener")) missing.decl("PasvListener");
    if (!@hasDecl(Net, "Address")) missing.decl("Address");

    if (!@hasDecl(Net, "controlListen")) missing.fnDecl("controlListen");
    if (!@hasDecl(Net, "acceptControl")) missing.fnDecl("acceptControl");

    if (!@hasDecl(Net, "pasvListen")) missing.fnDecl("pasvListen");
    if (!@hasDecl(Net, "pasvLocalAddr")) missing.fnDecl("pasvLocalAddr");
    if (!@hasDecl(Net, "formatPasvAddress")) missing.fnDecl("formatPasvAddress");
    if (!@hasDecl(Net, "acceptData")) missing.fnDecl("acceptData");
    if (!@hasDecl(Net, "closeListener")) missing.fnDecl("closeListener");

    if (!@hasDecl(Net, "read")) missing.fnDecl("read");
    if (!@hasDecl(Net, "write")) missing.fnDecl("write");
    if (!@hasDecl(Net, "closeConn")) missing.fnDecl("closeConn");
}
