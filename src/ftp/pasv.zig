/// Passive mode / data connection lifecycle state.
pub const State = enum {
    PasvIdle,
    PasvListening,
    DataConnected,
    Transferring,
    DataClosing,
};
