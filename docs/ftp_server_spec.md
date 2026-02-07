# Zig FTP Server Library — Design Plan

## Goals & Scope

- Provide a small, embeddable FTP **server** library written in Zig.
- Use **Zig 0.16 APIs** (compiler + `std`) throughout.
- Support **exactly one user account** (username + password) with classic `USER`/`PASS` authentication.
- Support **only one simultaneous FTP session** (one control connection at a time).
- Support **uploads and downloads** (`STOR`, `RETR`) using a **streaming** approach (low memory).
- Support **passive mode only** (`PASV`). **Active mode** (`PORT`) is out of scope.
- Prefer **single-threaded** operation (no threads). Use a cooperative event-loop style with **non-blocking I/O** (`error.WouldBlock`) when possible.
- Keep the feature set “basic but practically usable” (common clients should work with minimal configuration).
- **High priority**: organize code into logical modules (separate files) so no single file grows unwieldy, and document all public symbols with brief Zig-style doc comments (`///`).

## Non-Goals

- TLS/FTPS (`AUTH TLS`, implicit TLS).
- Multi-user / per-user roots / virtual permissions beyond what the FS abstraction implements.
- FXP (server-to-server transfers).
- Advanced RFC features (e.g., `REST` resume, `MLSD`, `UTF8`, `OPTS`, `SITE`).
- Full RFC compliance in edge cases (telnet negotiation, obscure command variants).

## High-Level Architecture

The library is split into:

1. **FTP protocol core**: command parsing, control-channel state machine, replies, transfer orchestration.
2. **Filesystem abstraction (VFS)**: implemented by the library user; enforces sandbox/path policy and performs storage operations.
3. **Network abstraction (TCP-ish)**: implemented by the library user; provides control listener/connection I/O and passive data listener/connection I/O without binding the FTP core to raw sockets.
4. **CLI harness**: a small executable that wires the core to `std.net` and an OS-backed VFS implementation (as a runnable demo/integration test harness).

### Event Loop Model (Single Thread)

- The server owns a control listener and at most **one** active session (one control connection).
- Progress is driven by calling `server.tick()` repeatedly:
  - accept a new control connection **only if** there is no active session,
  - otherwise either (a) do not accept (leave it queued in the listener backlog), or (b) accept and immediately refuse with `421 Too many users` then close (implementation choice; document behavior),
  - read/parse at most one command line per tick,
  - write pending replies (may partially write),
  - progress at most one data transfer (may partially read/write).
- All network I/O should be **non-blocking** and surface `error.WouldBlock`; `tick()` then simply moves on.
- If the target network stack cannot do `WouldBlock`, the network abstraction may provide an internal poll/dispatch, but the FTP core must remain single-threaded.

## Module Breakdown (Proposed Files)

Library (`src/ftp/`):

- `src/ftp/server.zig` — `FtpServer` type, session table, `tick()` driver, configuration, wiring between control + data submodules.
- `src/ftp/session.zig` — per-session state (auth, cwd handle, buffers, PASV state, transfer state).
- `src/ftp/control.zig` — command line parsing (`CRLF`), command dispatcher, reply queueing.
- `src/ftp/commands.zig` — command enum, argument parsing helpers, validation (e.g., missing args).
- `src/ftp/replies.zig` — reply formatting, common reply templates, mapping helper `replyFromError(...)`.
- `src/ftp/pasv.zig` — passive listener lifecycle + data connection acceptance rules.
- `src/ftp/transfer.zig` — streaming `RETR`/`STOR` and directory listing streaming.
- `src/ftp/interfaces_fs.zig` — filesystem interface definitions + required error set/types.
- `src/ftp/interfaces_net.zig` — network interface definitions + required error set/types.
- `src/ftp/limits.zig` — max line length, buffer sizes, timeouts, and defaults.

CLI harness (`src/cli/`):

- `src/cli/main.zig` — simple `ftp-server` executable: parse minimal args/env, start server loop, log basic events.
- `src/cli/net_std.zig` — `NetStd` implementation of network interface using `std.net` (non-blocking).
- `src/cli/vfs_os.zig` — `VfsOs` implementation that maps FTP paths to a configured OS root (chroot-like).

Optional examples/tests (`test/` or `src/ftp/test/`):

- `src/ftp/mock_net.zig` — deterministic mock network (scripted reads/writes).
- `src/ftp/mock_vfs.zig` — in-memory mock filesystem for unit/integration tests.

## Toolchain & Compatibility (Zig 0.16)

- All code must compile and run using **Zig 0.16** APIs (no older/newer `std` assumptions).
- The Zig compiler + standard library are located at `~/zig`.
  - Prefer invoking the compiler explicitly as `~/zig/zig` in local scripts/docs if needed.
  - Keep the library’s `build.zig` / CLI harness compatible with Zig 0.16’s build system APIs.

## Core Types & Configuration

### `Config`

- `listen_addr`: provided to the network implementation (or configured by CLI).
- `user`: `[]const u8`
- `password`: `[]const u8` (stored in memory; consider allowing hashed/opaque later)
- `banner`: optional `[]const u8` for the initial `220` message.
- `timeouts`: optional inactivity timeouts (control idle, pasv idle, transfer idle).
- `buffers`: sizes for command/reply/transfer chunks.

### Session Storage (Low-Memory)

Prefer no heap requirement:

- `FtpServer.init(...)` accepts user-provided storage:
  - `session: *Session` (single session storage)
  - `session_buffers: struct` with slices for command/reply/transfer buffers (or a single arena slice partitioned).
  - `scratch: []u8` a **small temporary buffer** used for transient formatting and argument staging (e.g., building `PWD`, `LIST` lines, storing `RNFR` path, assembling `227`).

If heap is acceptable, optionally accept an allocator for convenience (e.g., to allocate the single `Session` or grow buffers), but keep a no-heap path as the primary design.

Scratch buffer guidance (to keep it practical on low-memory targets):

- Target sizes: `512`–`2048` bytes.
- The FTP core must treat `scratch` as ephemeral: never store slices into it across ticks/commands.
- If a command needs more than `scratch` can hold (e.g., extremely long paths), fail with a deterministic reply (`501`/`553`) rather than allocating.

## FTP Feature Set

### Minimum Required Commands (MVP)

Authentication / session:

- `USER`, `PASS`, `QUIT`, `NOOP`

Introspection / basic interop:

- `SYST` (reply `215 UNIX Type: L8` or minimal)
- `TYPE` (support `TYPE I`; accept `TYPE A` but treat transfers as binary for simplicity)
- `FEAT` (list only what is supported: `PASV`, maybe `UTF8` if chosen)

Navigation:

- `PWD`
- `CWD`
- `CDUP`

Passive mode + transfers:

- `PASV` (open passive listener; reply `227`)
- `LIST` (directory listing via data connection)
- `RETR` (download)
- `STOR` (upload)

File ops:

- `DELE`
- `RNFR` / `RNTO` (rename as a 2-step stateful command pair)

### Optional / Nice-to-Have (Still Simple)

- `MKD`, `RMD`
- `SIZE` (for files)
- `MDTM` (mtime for files)
- `NLST` (name-only listing)
- `STAT` (control-channel status, no data connection)
- `OPTS UTF8 ON` / `UTF8` (if adding UTF-8 awareness)

### Commands Explicitly Not Supported

- `PORT`, `EPRT`, `EPSV` (only `PASV`)
- `REST` (resume)
- `APPE` (append)
- `ABOR` (abort) — optional later; initial design can only abort by closing the connection

## Control Connection State Machine

### States

1. `NewConn`
2. `BannerSent` (after sending `220`)
3. `NeedUser`
4. `NeedPass` (after `USER` accepted)
5. `Authed`
6. `Closing` (after `QUIT` or fatal error)
7. `Closed`

### Transitions (Simplified)

- `NewConn` → queue `220 <banner>` → `BannerSent`
- `BannerSent` → `NeedUser`
- `NeedUser`:
  - `USER <name>`:
    - if matches configured username: reply `331` → `NeedPass`
    - else: reply `530` (or `331` but always fail on PASS; pick one consistent strategy; simplest: fail early with `530`)
  - anything else: reply `530 Please login with USER and PASS`
- `NeedPass`:
  - `PASS <pass>`:
    - if matches configured password: reply `230` → `Authed`
    - else: reply `530` → `NeedUser` (reset)
- `Authed`:
  - allow navigation/ops/transfers
  - on `QUIT`: reply `221` → `Closing`
- `Closing`:
  - flush pending replies then close connection → `Closed`

### Command Parsing Rules

- Read ASCII-ish lines terminated by `\r\n` (CRLF).
- Enforce `max_line_len` (e.g., 512 or 1024). If exceeded: reply `500` and discard until next CRLF.
- Parse: `CMD` + optional `SP` + `ARG` (rest of line, not including CRLF).
- Case-insensitive command names; preserve argument bytes as-is.
- Support empty lines by ignoring or replying `500` (prefer ignore to be lenient).

### Reply Formatting

- Use standard single-line replies: `<code><space><text>\r\n`.
- For `FEAT`, use multiline form:
  - `211-Features:\r\n`
  - ` <feat>\r\n` lines
  - `211 End\r\n`
- Keep a small reply queue per session (e.g., ring buffer of 2–4 replies) or a single “pending reply” buffer if commands are processed one-at-a-time.

## Passive Mode (PASV) Data Connection State Machine

Each session has at most one passive listener and at most one active transfer.

### States

1. `PasvIdle` — no passive listener open
2. `PasvListening` — passive listener open, waiting for a client data connection
3. `DataConnected` — data connection accepted, ready for a command to use it
4. `Transferring` — `LIST`/`RETR`/`STOR` active
5. `DataClosing` — flushing/closing data connection

### Transitions & Rules

- On `PASV`:
  - If existing passive listener/connection exists, close it first (simplest rule).
  - Ask `Net` to open a new passive listener bound to the control connection’s local address (or a configured address).
  - Reply `227 Entering Passive Mode (h1,h2,h3,h4,p1,p2)` using the listener’s bound address/port.
  - State → `PasvListening`.

- On transfer command (`LIST`/`RETR`/`STOR`):
  - If not in `PasvListening` (or `DataConnected`), reply `425 Use PASV first`.
  - Attempt to accept a data connection:
    - if `error.WouldBlock`: reply `150` only after accepted; otherwise keep waiting and do not start transfer
    - if accepted: reply `150 Opening data connection` and proceed to `Transferring`
    - on accept error: reply `425 Can't open data connection`, close listener, state → `PasvIdle`

- After transfer completes successfully:
  - close data connection
  - reply `226 Transfer complete`
  - close passive listener (common simple behavior) and state → `PasvIdle`

- On transfer failure:
  - close data connection
  - reply `426 Connection closed; transfer aborted` or `451 Requested action aborted: local error`
  - close passive listener; state → `PasvIdle`

### Timeouts

- `PASV` idle timeout: if no data connection arrives within `pasv_timeout`, close listener.
- Transfer idle timeout: if no progress (no bytes read/written) within `transfer_timeout`, abort transfer.

## Proposed Interfaces (Zig-Style)

The preferred approach is **compile-time “duck typing”**: the library exposes `pub fn FtpServer(comptime Net: type, comptime Fs: type) type` and validates at comptime that the required declarations exist. This avoids vtable allocations and keeps runtime overhead low.

### Network Abstraction (`Net`)

File: `src/ftp/interfaces_net.zig`

```zig
pub const NetError = error{
    WouldBlock,
    Closed,
    Timeout,
    AddrUnavailable,
    Io,
};

pub fn NetInterface(comptime Net: type) type {
    // Required associated types:
    // - Net.ControlListener
    // - Net.Conn
    // - Net.PasvListener
    return struct {
        pub const Error = NetError;

        // Control listener (server socket).
        pub fn controlListen(net: *Net, addr: Net.Address) NetError!Net.ControlListener {}
        pub fn acceptControl(listener: *Net.ControlListener) NetError!?Net.Conn {}

        // Passive data listener (opened per-session, per PASV).
        pub fn pasvListen(net: *Net, bind_hint: PasvBindHint) NetError!Net.PasvListener {}
        pub fn pasvLocalAddr(listener: *Net.PasvListener) NetError!Net.Address {}
        pub fn acceptData(listener: *Net.PasvListener) NetError!?Net.Conn {}
        pub fn closeListener(listener: *Net.PasvListener) void {}

        // I/O primitives.
        pub fn read(conn: *Net.Conn, dst: []u8) NetError!usize {}
        pub fn write(conn: *Net.Conn, src: []const u8) NetError!usize {}
        pub fn closeConn(conn: *Net.Conn) void {}

        // Optional helpers.
        pub fn localAddr(conn: *Net.Conn) NetError!Net.Address {} // used for PASV bind hint
    };
}

pub const PasvBindHint = struct {
    // If provided, bind the data listener to the same local interface as the control connection.
    // Implementations may ignore or approximate this.
    control_local: ?Address = null,
};
```

Notes:

- `acceptControl` / `acceptData` return `?Conn` where `null` means “no connection ready yet” (non-blocking accept).
- `read`/`write` may return `error.WouldBlock` and must not block.
- `Net.Address` is an implementation-defined address type (e.g., IPv4 only for MVP). For MVP PASV, **IPv4** is sufficient; add IPv6 later if desired.

### Filesystem Abstraction (`Fs` / VFS)

File: `src/ftp/interfaces_fs.zig`

Design goals:

- The FTP core never joins paths, never “chroots”, never touches OS paths.
- All path resolution and sandbox enforcement lives in `Fs`.
- All operations are streaming and use small buffers.

```zig
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
    // Required associated types:
    // - Fs.Cwd (opaque per-session current directory handle/state)
    // - Fs.FileReader / Fs.FileWriter (stream handles)
    // - Fs.DirIter (directory listing iterator)
    return struct {
        pub const Error = FsError;

        // Current directory management.
        pub fn cwdInit(fs: *Fs) FsError!Fs.Cwd {}
        pub fn cwdPwd(fs: *Fs, cwd: *const Fs.Cwd, out: []u8) FsError![]const u8 {}
        pub fn cwdChange(fs: *Fs, cwd: *Fs.Cwd, user_path: []const u8) FsError!void {}
        pub fn cwdUp(fs: *Fs, cwd: *Fs.Cwd) FsError!void {}

        // Listing.
        pub fn dirOpen(fs: *Fs, cwd: *const Fs.Cwd, user_path: ?[]const u8) FsError!Fs.DirIter {}
        pub fn dirNext(fs: *Fs, it: *Fs.DirIter) FsError!?DirEntry {}
        pub fn dirClose(fs: *Fs, it: *Fs.DirIter) void {}

        // File transfers.
        pub fn openRead(fs: *Fs, cwd: *const Fs.Cwd, user_path: []const u8) FsError!Fs.FileReader {}
        pub fn openWriteTrunc(fs: *Fs, cwd: *const Fs.Cwd, user_path: []const u8) FsError!Fs.FileWriter {}
        pub fn readFile(fs: *Fs, r: *Fs.FileReader, dst: []u8) FsError!usize {}
        pub fn writeFile(fs: *Fs, w: *Fs.FileWriter, src: []const u8) FsError!usize {}
        pub fn closeRead(fs: *Fs, r: *Fs.FileReader) void {}
        pub fn closeWrite(fs: *Fs, w: *Fs.FileWriter) void {}

        // File operations.
        pub fn delete(fs: *Fs, cwd: *const Fs.Cwd, user_path: []const u8) FsError!void {}
        pub fn rename(fs: *Fs, cwd: *const Fs.Cwd, from: []const u8, to: []const u8) FsError!void {}

        // Optional ops (only used if enabled).
        pub fn makeDir(fs: *Fs, cwd: *const Fs.Cwd, user_path: []const u8) FsError!void {}
        pub fn removeDir(fs: *Fs, cwd: *const Fs.Cwd, user_path: []const u8) FsError!void {}
        pub fn fileSize(fs: *Fs, cwd: *const Fs.Cwd, user_path: []const u8) FsError!u64 {}
        pub fn fileMtime(fs: *Fs, cwd: *const Fs.Cwd, user_path: []const u8) FsError!i64 {}
    };
}
```

Notes:

- `user_path` is the raw FTP path argument (may be absolute or relative). The `Fs` implementation decides how to interpret it and must enforce sandboxing.
- `cwdPwd` writes a printable PWD string into `out` to avoid allocations.
- For `dirNext`, the returned `DirEntry.name` may be valid only until the next iterator call; the FTP core should copy/format immediately.

### Authentication (Single User)

Keep it minimal: the FTP core compares `USER` and `PASS` to `Config.user` / `Config.password`.

Optional extension hook (later): `AuthProvider` interface for hashed passwords or external auth.

## Transfer Streaming Design

### Buffers

- Use a single `transfer_buf` per session (e.g., 1–4 KiB) reused for:
  - `RETR`: `fs.readFile` → `net.write`
  - `STOR`: `net.read` → `fs.writeFile`
  - `LIST`: format each entry into a small `list_line_buf`, then `net.write`

### `RETR` (Download)

- Validate authed + PASV ready.
- Open file reader via VFS.
- Accept data connection, send `150`.
- Loop (across ticks):
  - `fs.readFile(..., transfer_buf)`:
    - `0` → EOF
    - `n > 0` → write to data conn (handle partial writes; keep `offset`)
  - On completion: close file + data conn, reply `226`.

### `STOR` (Upload)

- Validate authed + PASV ready.
- Open file writer (truncate).
- Accept data connection, send `150`.
- Loop (across ticks):
  - `net.read(..., transfer_buf)`:
    - `0` or `error.Closed` → EOF (client closed) → finalize
    - `n > 0` → `fs.writeFile` (handle partial file writes if supported; simplest: require VFS writes all or return how many)
  - On completion: close file + data conn, reply `226`.

### `LIST` (Directory Listing)

- Open directory iterator via VFS.
- Accept data connection, send `150`.
- For each entry:
  - Format a minimal UNIX-like line (or configurable):
    - `drwxr-xr-x 1 owner group <size> <date> <name>\r\n`
    - If metadata missing, use placeholders (`-` / `0` / fixed date).
- Stream lines one-by-one, handling partial writes.
- Close iterator + data conn, reply `226`.

## Command Handling Details

### `RNFR` / `RNTO` Pairing

- `RNFR <path>` stores a “pending rename from” string in session state (bounded buffer).
- `RNTO <path>` performs rename and clears pending state.
- If `RNTO` arrives without `RNFR`: reply `503 Bad sequence of commands`.
- If another command arrives while rename is pending: either clear pending state or allow only `RNTO`/`RNFR`/`QUIT` (pick a simple consistent rule; recommended: allow only `RNTO`/`QUIT`, otherwise `503`).

### `CWD` / `PWD` / `CDUP`

- `CWD` delegates to `fs.cwdChange`; errors map to `550` / `553` depending on cause.
- `PWD` uses `fs.cwdPwd` and replies `257 "<pwd>"`.

### `TYPE`

- Accept `TYPE I` and store transfer type (binary).
- Optionally accept `TYPE A` but still treat as binary; reply `200` to keep clients happy.

### `SYST` / `FEAT`

- `SYST`: `215 UNIX Type: L8` (common expectation).
- `FEAT`: advertise only implemented features (`PASV`, maybe `SIZE`, `MDTM` if enabled).

## Security & Safety Considerations

### Filesystem / Path Traversal Prevention

- The FTP core never manipulates OS paths.
- All potentially unsafe inputs (`CWD`, `RETR`, `STOR`, `DELE`, rename paths) are passed verbatim to VFS.
- The VFS implementation must:
  - normalize paths (`.` / `..`),
  - prevent escaping the sandbox (chroot-like),
  - enforce read/write permissions and file type rules,
  - reject invalid encodings if required.
- The FTP core should still apply minimal validation:
  - reject NUL bytes in path arguments,
  - enforce maximum path argument length (bounded by session buffer).

### Authentication Handling

- Avoid leaking which part failed where possible (optional). For simplicity, reply `530` on failure.
- Use constant-time compare for password if feasible (`std.crypto.utils.timingSafeEql`).
- Enforce a maximum number of failed attempts per connection (optional), else clients can brute force.

### Input Validation / Robustness

- Maximum command line length (protect memory).
- Only one simultaneous session (one control connection).
- One transfer at a time per session; close/cleanup on protocol errors.
- Timeouts for idle control connections and PASV listeners.
- Explicit state transitions; `503` for invalid command sequences.

## Error Handling & Reply Code Mapping

### Error Handling Strategy

- The FTP core uses a small internal error union:
  - `ProtocolError` (bad command, bad sequence)
  - `AuthError`
  - `FsError` (from VFS)
  - `NetError` (from Net)
- Each command handler returns either `ok`, or an error that is mapped to a reply and typically keeps the session alive unless it is a fatal network/control failure.

### Recommended Reply Code Mapping (Minimal)

Protocol / parsing:

- unknown command → `502 Command not implemented`
- syntax error / missing arg → `501 Syntax error in parameters or arguments`
- bad sequence → `503 Bad sequence of commands`

Authentication:

- not logged in → `530 Not logged in`
- `USER` ok → `331 User name okay, need password`
- login success → `230 User logged in`

Passive / data:

- missing PASV → `425 Use PASV first`
- data open failed → `425 Can't open data connection`
- transfer started → `150 File status okay; about to open data connection`
- transfer ok → `226 Closing data connection`
- transfer aborted / data closed early → `426 Connection closed; transfer aborted`

Filesystem mapping (examples):

- `FsError.NotFound` → `550 File not found`
- `FsError.PermissionDenied` / `ReadOnly` → `550 Permission denied`
- `FsError.InvalidPath` → `553 Requested action not taken. File name not allowed`
- `FsError.Exists` → `550 File exists`
- `FsError.NoSpace` → `452 Insufficient storage space`
- `FsError.Io` → `451 Requested action aborted: local error in processing`

Network mapping:

- control connection closed → session ends silently
- data `NetError.Io` during transfer → `426` then cleanup

## Testing Strategy

### Unit Tests (Pure Logic)

1. **Command parser**
   - CRLF handling, max line length, case-insensitive commands
   - commands with/without args, trimming rules
2. **Control state machine**
   - correct sequences for `USER`/`PASS`
   - rejection of commands before auth
   - `RNFR`/`RNTO` sequencing
3. **Reply formatting**
   - correct codes and CRLF
   - multiline `FEAT` formatting
4. **PASV lifecycle rules**
   - `PASV` then `LIST` requires accept
   - new `PASV` closes old listener

### Integration Tests (Mock Net + Mock FS)

Use deterministic mocks to simulate a client:

- Mock control connection feeds scripted command lines; captures replies.
- Mock Net can simulate:
  - non-blocking accept (`null` until triggered),
  - partial reads/writes,
  - connection closure mid-transfer.
- Mock FS can simulate:
  - directory tree, reads/writes, errors (NotFound/PermissionDenied/NoSpace).

Scenarios:

- login + `PWD` + `CWD` + `LIST`
- `STOR` then `RETR` same file
- rename flow (`RNFR`/`RNTO`) and error cases
- attempts before login → `530`
- second concurrent control connection refused (either stays pending in accept backlog or receives `421`, per chosen behavior)
- missing `PASV` before transfer → `425`
- partial write handling on data connection

### CLI Harness Smoke Tests (Optional)

- Run `ftp-server` and use a real FTP client (manual) or a small scripted client to verify interop:
  - connect, login, list, upload, download, delete, rename.

## Implementation Notes (Keep It Minimal)

- Start with IPv4-only PASV to reduce complexity. Document limitation.
- Keep command set small and explicit; return `502` for the rest.
- Prefer fixed buffers and bounded state to keep memory predictable.
- Treat all transfers as binary; accept `TYPE` but do not implement text transformations.
- When in doubt, implement strict state machines (`503`) rather than “clever recovery”.
