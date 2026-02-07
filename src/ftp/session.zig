const pasv = @import("pasv.zig");
const limits = @import("limits.zig");

/// Authentication state for the control session.
pub const AuthState = enum {
    NeedUser,
    NeedPass,
    Authed,
    Closing,
};

/// Transfer type selected by `TYPE`.
pub const TransferType = enum {
    binary,
};

/// Per-session state used by the control state machine.
pub const Session = struct {
    auth_state: AuthState = .NeedUser,
    transfer_type: TransferType = .binary,
    cwd_ready: bool = false,
    pasv_state: pasv.State = .PasvIdle,
    rename_from_len: usize = 0,
    rename_from: [limits.command_max]u8 = [_]u8{0} ** limits.command_max,
};
