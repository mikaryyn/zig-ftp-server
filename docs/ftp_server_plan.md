# FTP Server ExecPlan (Zig 0.16, single-session, PASV-only)

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

This plan is written to be used alongside `docs/ftp_server_spec.md`, which is the authoritative requirements document for protocol scope, state machines, and the `Net` and `Fs` interfaces.

## Purpose / Big Picture

The goal is to deliver a small, embeddable FTP **server** library written in Zig 0.16 that is “basic but practically usable” with common FTP clients. The library is single-threaded and advances via a cooperative `tick()` method that must never block. The server supports exactly one user account and only one control session at a time. It supports only passive mode (`PASV`) for data connections, and it implements streaming uploads and downloads so it can run with small fixed buffers.

This repository must also include a runnable CLI harness that wires the library to `std.net` (non-blocking sockets) and to an OS-backed filesystem sandbox rooted at a directory on disk. The CLI is used as a human-facing demo and as a smoke test harness.

## Progress

- [x] (2026-02-07 18:45Z) Record initial design decisions (below) and keep this plan updated during implementation.
- [x] (2026-02-07 18:45Z) Milestone 1: Scaffolding + compile-time interfaces + first tests pass via `zig build test`.
- [x] (2026-02-07 19:10Z) Milestone 2: Minimal CLI harness (`NetStd`) that accepts a control connection and closes (or sends a banner), proving the app runs.
- [x] (2026-02-07 20:44Z) Milestone 3: Control-channel CRLF line reader + reply writer (non-blocking) with unit tests.
- [x] (2026-02-07 20:53Z) Milestone 4: Session state machine + auth + basic commands (`USER`, `PASS`, `QUIT`, `NOOP`, `SYST`, `TYPE`, `FEAT`) with mock-net tests.
- [x] (2026-02-07 21:03Z) Milestone 5: Fs interface usage + navigation commands (`PWD`, `CWD`, `CDUP`) with mock-fs tests.
- [x] (2026-02-07 22:05Z) Milestone 6: CLI harness (`NetStd` + `VfsOs`) wired to core + manual “login and PWD” smoke test.
- [x] (2026-02-07 22:32Z) Milestone 7: PASV lifecycle + data accept plumbing + `PASV` command with tests and manual smoke test.
- [ ] Milestone 8: `LIST` streaming implementation with tests and manual smoke test.
- [ ] Milestone 9: `RETR` streaming download with tests and manual smoke test.
- [ ] Milestone 10: `STOR` streaming upload with tests and manual smoke test.
- [ ] Milestone 11: File ops (`DELE`, `RNFR`/`RNTO`) + optional ops (`MKD`, `RMD`, `SIZE`, `MDTM`) if enabled.
- [ ] Milestone 12: Timeouts + limits hardening + error→reply mapping audit + integration tests.
- [ ] Milestone 13: Documentation polish (README + docs) + final acceptance run-through.

## Surprises & Discoveries

- Observation: Local `zig build test` used Zig 0.15.2, and the existing `build.zig.zon` fingerprint failed validation.
  Evidence: Build error: "invalid fingerprint: 0xddc27b248372ca1d; ... use this value: 0x5ef2039982c339".

- Observation: CLI code paths written for newer Zig APIs (`std.process.Init`, direct parent-path imports from `src/cli/*`) failed under Zig 0.15.2 module boundaries.
  Evidence: `zig build` errors included "root source file struct 'process' has no member named 'Init'" and "import of file outside module path".

## Decision Log

- Decision: When a second control connection arrives while a session is active, accept it, attempt to send `421 Too many users`, then close it (best-effort; if writing would block, close anyway).
  Rationale: This avoids clients hanging in the backlog and makes the “single session only” limit explicit.
  Date/Author: 2026-02-07 / Codex

- Decision: When `RNFR` is pending, allow only `RNTO` and `QUIT`; respond `503 Bad sequence of commands` to anything else and keep the pending rename.
  Rationale: This keeps sequencing strict and deterministic and matches the spec’s suggested “simple consistent rule”.
  Date/Author: 2026-02-07 / Codex

- Decision: MVP PASV is IPv4-only; `PASV` replies always use `227 ... (h1,h2,h3,h4,p1,p2)` derived from the passive listener’s bound IPv4 address and port.
  Rationale: IPv4-only reduces surface area and is sufficient for MVP client interop; the spec explicitly allows this.
  Date/Author: 2026-02-07 / Codex

- Decision: `LIST` output uses a minimal, consistent UNIX-like format with placeholders when metadata is missing; each entry line always ends with `\r\n`.
  Rationale: Many clients only require a consistent CRLF-terminated listing; placeholders are permitted by the spec.
  Date/Author: 2026-02-07 / Codex

- Decision: Ship a minimal CLI harness early (Milestone 2) that only accepts and closes a connection (optionally with a banner) before the core protocol logic is implemented.
  Rationale: The user requested runnable deliverables as early as possible; this provides immediate proof the app runs while keeping the protocol work incremental.
  Date/Author: 2026-02-07 / Codex

- Decision: `TYPE` uses `504 Command not implemented for that parameter` for unsupported type values.
  Rationale: `504` clearly indicates command support exists but specific parameters are unsupported, which is more precise than a generic syntax error.
  Date/Author: 2026-02-07 / Codex

- Decision: Before Milestones 8–10 land transfer implementations, `LIST`/`RETR`/`STOR` return `425 Use PASV first` when no passive listener exists and `502 Command not implemented` once PASV is prepared.
  Rationale: This enforces the sequencing rule now while making unsupported transfer execution explicit after PASV setup.
  Date/Author: 2026-02-07 / Codex

## Outcomes & Retrospective

- Milestone 1 delivered the scaffolding: limits/constants, Net/Fs interface definitions with compile-time validation, a placeholder public API, and a passing `zig build test` with mock instantiation. Remaining work proceeds with control-channel I/O and state machine implementation.
- Milestone 2 delivered a runnable CLI harness (`ftp-server`) with a minimal non-blocking listener/accept loop (`NetStd`) that accepts one connection, optionally writes a banner, and closes, proving the app can run and be smoke-tested with `nc`.
- Milestone 3 delivered `src/ftp/control.zig` (non-blocking CRLF line reader with long-line discard), `src/ftp/replies.zig` (fixed-buffer reply formatter + resumable partial-writes), and `src/ftp/mock_net.zig` (deterministic partial I/O / `WouldBlock` scripts), with unit tests covering split CRLF, multi-line buffering, empty lines, long-line handling, FEAT formatting, and partial-write flushing.
- Milestone 4 delivered `src/ftp/commands.zig`, `src/ftp/session.zig`, and `src/ftp/server.zig` with a non-blocking single-session `tick()` driver implementing `USER`, `PASS`, `QUIT`, `NOOP`, `SYST`, `TYPE`, and `FEAT`; `src/ftp/mock_net.zig` was extended with scripted control accepts so tests now cover full login command sequencing and `421` rejection of concurrent control connections.
- Milestone 5 delivered `PWD`/`CWD`/`CDUP` wired to `Fs.cwdPwd`/`Fs.cwdChange`/`Fs.cwdUp`, session CWD initialization during login, `src/ftp/mock_vfs.zig` in-memory navigation tests, `src/ftp/transfer.zig` placeholder state, and validated VFS error-to-reply mapping (`550`/`553`/`451`) under `zig build test`.
- Milestone 6 delivered a full CLI harness wired to the protocol core: `src/cli/main.zig` now runs the `FtpServer` tick loop with `--listen`/`--root`/`--user`/`--pass`, `src/cli/net_std.zig` satisfies the compile-time `Net` interface for control-channel operation using non-blocking `std.net`, and `src/cli/vfs_os.zig` provides a rooted OS-backed `Fs` implementation for `cwd` operations with path normalization and NUL-byte rejection. Manual smoke validation with `./zig-out/bin/ftp-server` + `nc` confirmed the expected `220`/`331`/`230`/`257`/`221` sequence.
- Milestone 7 delivered `src/ftp/pasv.zig` state definitions, session/server passive lifecycle wiring, `PASV` command support with `227` tuple formatting through the `Net` abstraction, passive accept polling (`PasvListening`→`DataConnected`), and mock-net tests proving repeated `PASV` closes prior listener/connection plus `425` enforcement for `LIST`/`RETR`/`STOR` without PASV.

## Context and Orientation

Current repository state at plan creation is intentionally minimal. `build.zig` defines a Zig module named `ftp_server` rooted at `src/root.zig` and provides `zig build test`. `src/root.zig` is currently empty and must become the library’s public entry point. The two documents in `docs/` are intended to be the primary source of truth for this feature: the spec defines what the server must do, while this plan defines the incremental path to a working implementation and how to validate it at each stage.

This plan uses the following terms in their plain meaning. A “control connection” is the TCP connection where the client sends commands like `USER` and receives replies like `220`. A “data connection” is the separate TCP connection used for the bytes of `LIST`, `RETR`, and `STOR`. “Passive mode” (`PASV`) is when the server opens a listener and the client connects to it for the data connection. A “tick” is a single, bounded unit of work in a single-threaded event loop; `tick()` must never block and must tolerate non-blocking I/O returning `error.WouldBlock`.

## Plan of Work

The implementation follows the module split described in `docs/ftp_server_spec.md`: protocol core, filesystem abstraction (VFS), network abstraction, and a small CLI harness. This plan adds the repository-specific details that make implementation straightforward for a new contributor: concrete file paths, the expected public API, and milestone-by-milestone validation.

The overall strategy is to make core logic testable early with deterministic mocks, while also delivering a runnable CLI as soon as possible. Milestone 2 introduces a minimal CLI that accepts a connection to prove the application runs; once the control-channel and state machine are stable, Milestone 6 wires the CLI to the full core and filesystem. Each milestone must remain “incremental and runnable”: at minimum `zig build test` must pass at the end of every milestone, and starting at Milestone 2 the CLI harness must be runnable for manual verification (even if it only accepts and closes a connection at first).

### Library API shape and storage model

The spec prefers a no-heap path. This plan expects the core library to provide an initializer that takes caller-owned storage (the CLI can allocate this storage, but the library should not require an allocator).

The target public shape is:

    pub fn FtpServer(comptime Net: type, comptime Fs: type) type

with an initializer similar to:

    pub fn initNoHeap(
        net: *Net,
        fs: *Fs,
        config: Config,
        storage: *Storage,
    ) !Self

where `Storage` contains the single session state and fixed buffers. A practical starting point for sizes (tunable later, but stable early) is: command line buffer 1 KiB, reply buffer 1 KiB, transfer buffer 4 KiB, scratch buffer 1–2 KiB. The implementation must not retain slices into the scratch buffer across ticks or across commands.

`tick()` should accept a monotonically increasing “now” value (for timeouts) in milliseconds, even if timeouts are disabled in early milestones. The CLI harness can provide “now” from `std.time` and can yield/sleep between ticks to avoid busy-waiting.

## Concrete Steps

Commands in this section assume the working directory is the repository root (`modules/zig-ftp-server`).

### Milestone 1 — Scaffolding, interfaces, compile-time validation

Create the file layout expected by the spec without implementing behavior yet. Add `src/ftp/interfaces_net.zig`, `src/ftp/interfaces_fs.zig`, and `src/ftp/limits.zig`. Add a small compile-time validator (a helper that uses `@hasDecl` and emits `@compileError` with a clear message) and ensure `FtpServer(Net, Fs)` cannot be instantiated unless the type provides the required associated types and functions.

Update `src/root.zig` to export the public API surface and to re-export the interface modules so users can implement `Net` and `Fs` without hunting for internal paths.

Add the first tests that instantiate `FtpServer(MockNet, MockFs)` and verify compilation and basic initialization. At this milestone there does not need to be a functional server; the deliverable is a stable skeleton with the right contracts.

Run:

    zig build test

Expected: the test step passes; missing interface declarations produce a single actionable compile error (add a negative test if practical).

### Milestone 2 — Minimal CLI harness (accept + close smoke test)

Introduce a runnable CLI as early as possible, even before the core protocol logic exists. Add `src/cli/main.zig` and `src/cli/net_std.zig` and update `build.zig` to build an executable (recommended name `ftp-server`) plus a `run` step. The initial CLI only needs to listen on a TCP address, accept a single connection, optionally attempt to write a banner (`220 FTP Server Ready\r\n`), then close. This is a deliberately small “does it run and accept a connection?” deliverable.

The `NetStd` module should provide a minimal, non-blocking control listener and accept loop using `std.net`. Even if it does not yet implement the full `Net` interface, it should be written so it can be extended later without throwing away the code.

Run:

    zig build
    zig build run -- --listen 127.0.0.1:2121

Manual smoke test (one simple option):

    nc 127.0.0.1 2121

Expected: the TCP connection succeeds and is immediately closed (or receives a single banner line before closing). This confirms the CLI harness is runnable.

### Milestone 3 — Control-channel CRLF line reader and reply writer (non-blocking)

Implement robust, unit-tested primitives for reading commands and writing replies without blocking. Add `src/ftp/control.zig` to implement a CRLF (`\r\n`) line reader driven by `Net.read`, including enforcement of a maximum line length (from `limits.zig`) and a deterministic “too long” behavior (discard until CRLF and allow the caller to reply `500`). Add `src/ftp/replies.zig` to format replies into fixed buffers, including multiline `FEAT` formatting as specified, and to support partial writes (track offsets and resume on later ticks).

Introduce a deterministic `src/ftp/mock_net.zig` to simulate: partial reads, partial writes, `error.WouldBlock`, and connection closure. Unit test the line reader and reply writer with a focus on boundary conditions (CRLF split across reads, multiple lines in one read, empty lines, and long lines).

Run:

    zig build test

Expected: tests pass, including explicit coverage for partial I/O and long-line handling.

### Milestone 4 — Session state machine, auth, and basic commands

Implement the control-channel state machine and a minimal command dispatcher. Add `src/ftp/commands.zig` to parse a single FTP command line into a case-insensitive command token and an argument slice (the raw “rest of line”, without CRLF). Add `src/ftp/session.zig` to store per-session state: control state (`NeedUser`, `NeedPass`, `Authed`, etc.), pending output state, and any small per-session variables (such as remembered username for `USER`/`PASS`, transfer type set by `TYPE`, and pending `RNFR` data buffer reserved for later).

Add `src/ftp/server.zig` implementing the single-session server driver and `tick(now_millis)`. `tick()` must (1) accept a control connection when idle, (2) send a `220` banner, (3) read and process at most one command line per tick, (4) write pending output as far as possible, and (5) never block when I/O would block.

Implement these commands with the reply codes and semantics from the spec: `USER`, `PASS`, `QUIT`, `NOOP`, `SYST`, `TYPE`, and `FEAT`. Unknown commands reply `502`. Before authentication completes, commands other than `USER`, `PASS`, and `QUIT` reply `530`. `TYPE I` must be accepted; `TYPE A` may be accepted but treated as binary; unsupported type values should reply `504` or `501` consistently (choose one and document in Decision Log if it becomes important for client interop).

Deliver this milestone with mock-net tests that script a full login flow and verify exact reply codes and CRLF termination. Also add a test that demonstrates the chosen behavior for “second control connection” (`421` then close).

Run:

    zig build test

Expected: scripted control-session tests pass, including the correct ordering of `220`, `331`, `230`, and `221` for a normal login and quit.

### Milestone 5 — Filesystem (VFS) usage for `PWD`, `CWD`, `CDUP`

Add filesystem-aware commands and mock filesystem tests. Add (or extend) `src/ftp/transfer.zig` as a placeholder for transfer-related enums/state referenced by `Session` (even if transfers are not implemented yet). On successful login, initialize an `Fs.Cwd` handle using `Fs.cwdInit` and store it in the session. Implement `PWD` using `Fs.cwdPwd` and reply `257 "<pwd>"` (including quotes as required by typical clients). Implement `CWD` and `CDUP` through `Fs.cwdChange` and `Fs.cwdUp`. Ensure errors are mapped to `550`/`553`/`451` as recommended by the spec.

Introduce `src/ftp/mock_vfs.zig` that implements the `Fs` interface in-memory (a small directory tree is sufficient). Add tests that verify navigation behavior and error mapping without touching the OS filesystem.

Run:

    zig build test

Expected: navigation tests pass; no OS filesystem access is required.

### Milestone 6 — CLI harness (`NetStd` + `VfsOs`) wired to core + first manual smoke test

Upgrade the early CLI to the real harness. Update `src/cli/net_std.zig` to fully implement the `Net` interface using `std.net` with non-blocking control sockets; all reads and writes must surface `error.WouldBlock` rather than blocking. Add `src/cli/vfs_os.zig` implementing the `Fs` interface using `std.fs`, rooted at a configured directory; it must normalize paths, reject NUL bytes, and prevent escaping the root.

Implement `src/cli/main.zig` to parse minimal flags (`--listen`, `--root`, `--user`, `--pass`), allocate or define storage buffers, create the server, and loop calling `tick()` with a monotonic time value.

Run:

    zig build
    zig build run -- --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test

Manual smoke test (one simple option):

    printf "USER test\r\nPASS test\r\nPWD\r\nQUIT\r\n" | nc 127.0.0.1 2121

Expected: the server responds with `220`, `331`, `230`, `257`, and `221` in order, each on its own CRLF-terminated line.

### Milestone 7 — PASV lifecycle and `PASV` command

Implement passive mode without transfers yet. Add `src/ftp/pasv.zig` (or keep this state in `session.zig` if preferred, but the spec suggests a module) with the PASV state machine from the spec (`PasvIdle`, `PasvListening`, `DataConnected`, `Transferring`, `DataClosing`). Implement `PASV` so it closes any existing passive listener or data connection first, opens a new passive listener via `Net.pasvListen`, and replies `227` with the IPv4 address and port in `(h1,h2,h3,h4,p1,p2)` form. Implement the rule that transfer commands require passive mode by replying `425 Use PASV first` for `LIST`, `RETR`, and `STOR` until the later milestones implement them.

Add mock-net tests that verify repeated `PASV` closes old listeners and that `LIST`/`RETR`/`STOR` without PASV reply `425`. Update `NetStd` to implement the passive listener operations in a non-blocking way.

Run:

    zig build test
    zig build run -- --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test

Expected: `PASV` returns a syntactically correct `227` reply and clients can connect to the advertised port (even though the server may immediately close until transfers are implemented).

### Milestone 8 — `LIST` streaming over the data connection

Implement directory listing transfers. Implement `LIST` so that it requires authentication and passive mode, waits for a data connection accept (non-blocking), and only sends `150` once a data connection is accepted. Then it must open a directory iterator via `Fs.dirOpen`, format each entry line, and stream the listing line-by-line to the data connection, handling partial writes. Close the iterator and data connection on completion, reply `226`, and close the passive listener (as the spec suggests for a simple rule).

Adopt a stable MVP listing format and keep it deterministic: use `drwxr-xr-x` for directories and `-rw-r--r--` for files, fixed owner/group strings, numeric size (use `0` if unknown), and a fixed date `Jan 01 00:00` if metadata is missing. Always end listing lines with `\r\n`.

Add mock tests that ensure (1) partial writes are handled, (2) listing output includes CRLF, and (3) control replies are correctly sequenced (`150` then `226`). Then manually verify with a real FTP client by running `ls` in passive mode.

Run:

    zig build test
    zig build run -- --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test

Expected: a real client can perform `LIST` and sees output; the control channel ends with `226`.

### Milestone 9 — `RETR` streaming download

Implement `RETR path` as a streaming download. Require authentication and passive mode. Open the file via `Fs.openRead`, accept the data connection non-blockingly, reply `150` after accept, then loop across ticks: read from the file into the transfer buffer and write to the data connection with correct handling of partial writes (including preserving an offset for the current chunk). On EOF, close the file and data connection, reply `226`, and close the passive listener. Map filesystem errors (not found, permission denied, invalid path) to the reply codes in the spec.

Add mock-fs tests with deterministic contents and mock-net tests with partial writes. Then manually verify with a real client by downloading a file under the configured root and checking it matches byte-for-byte.

Run:

    zig build test

Expected: `RETR` works against both mocks and the CLI harness.

### Milestone 10 — `STOR` streaming upload

Implement `STOR path` as a streaming upload. Require authentication and passive mode. Open the target via `Fs.openWriteTrunc`, accept the data connection non-blockingly, reply `150` after accept, then loop across ticks reading from the data connection and writing to the file. Treat `Net.read` returning `0` or `error.Closed` as EOF from the client. Handle partial file writes if the filesystem abstraction supports returning a short write; if the OS-backed VFS always writes fully, keep the core code prepared for partial writes anyway by tracking a file-write offset into the current buffer.

Add mock-net tests feeding bytes in chunks and exercising `WouldBlock`. Then manually verify by uploading via a real client and checking the resulting file contents on disk.

Run:

    zig build test

Expected: `STOR` writes correct bytes and replies `150` then `226`.

### Milestone 11 — File operations and optional extras

Implement file operations required by the spec: `DELE` (via `Fs.delete`) and rename via the `RNFR`/`RNTO` pair (via `Fs.rename`) with the strict sequencing rule recorded in the Decision Log. Add tests for correct sequencing and correct error mapping. Expand `FEAT` to advertise only what is actually implemented.

If desired and if the filesystem implementation supports them, implement `MKD`, `RMD`, `SIZE`, and `MDTM` as “nice to have” commands. If not implemented, respond `502` consistently.

Run:

    zig build test

Expected: file ops tests pass, including `503` sequencing errors and representative `550`/`553`/`451` mappings.

### Milestone 12 — Timeouts, limits, and error mapping audit

Add timeout tracking and robustness hardening. Implement a PASV idle timeout (close passive listener if no data connection arrives), a transfer idle timeout (abort transfer if no progress), and an optional control idle timeout (close control connection after inactivity) as described in the spec. Make timeouts testable by using the `now_millis` value passed to `tick()` and by keeping the logic deterministic under mocks.

Enforce maximum command line length and maximum path argument length based on the fixed buffers. Reject NUL in path arguments at the core layer (even though the VFS must also defend itself). Audit error→reply mapping against the spec’s recommended mapping and add a small number of targeted tests that lock in the intended behavior.

Run:

    zig build test

Expected: timeout behavior is deterministic and covered by tests that do not rely on real time passing.

### Milestone 13 — Documentation polish and final acceptance

Replace `README.md` with build and usage instructions for the CLI harness, a supported-commands list, and a limitations section (single session, PASV-only, IPv4-only). Add a short “How to implement `Net` and `Fs`” note under `docs/` that points to the interface files and describes what `tick()` guarantees (non-blocking, cooperative progress, partial I/O handling).

Complete a final manual acceptance run: login succeeds with correct credentials and fails with incorrect ones; `PWD`, `CWD`, `LIST`, `STOR`, `RETR`, `DELE`, `RNFR`/`RNTO`, `TYPE`, `SYST`, and `FEAT` behave as specified; `PORT` is rejected; and a second concurrent control connection receives `421`.

Run:

    zig build test
    zig build
    zig build run -- --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test

## Validation and Acceptance

The feature is accepted when `zig build test` passes and the CLI harness can be used with a real FTP client to complete a basic workflow: connect, authenticate, list a directory, upload a file, download the same file (byte-for-byte match), rename it, delete it, and quit, all using passive mode. The server must remain single-threaded and non-blocking; it must progress solely by repeated calls to `tick()` and must correctly handle `error.WouldBlock` and partial reads/writes on both control and data connections.

## Idempotence and Recovery

Milestones should be safe to repeat. If the server gets into a bad state during manual testing, stop it and restart it. If build artifacts cause confusing behavior, deleting `.zig-cache/` and rerunning `zig build test` is safe. Avoid “big bang” changes; end every milestone with passing tests before proceeding.

## Artifacts and Notes

An example control-channel transcript for a simple login and quit is shown here as a sanity reference (banner text may differ by configuration):

    S: 220 FTP Server Ready\r\n
    C: USER test\r\n
    S: 331 User name okay, need password\r\n
    C: PASS test\r\n
    S: 230 User logged in\r\n
    C: SYST\r\n
    S: 215 UNIX Type: L8\r\n
    C: QUIT\r\n
    S: 221 Goodbye\r\n

## Interfaces and Dependencies

This project targets Zig 0.16 and uses no required heap allocation in the core library. The library should compile-time validate `Net` and `Fs` implementations and emit actionable errors when a required declaration is missing. The definitive interface definitions and error sets are in `docs/ftp_server_spec.md` and must be implemented in `src/ftp/interfaces_net.zig` and `src/ftp/interfaces_fs.zig`. The CLI harness (`src/cli/**`) may use an allocator for convenience, but the library core must remain usable in fixed-memory environments.

Plan Update Notes (2026-02-07): Marked Milestone 1 complete, recorded the Zig fingerprint mismatch discovery, and summarized Milestone 1 outcomes after landing the scaffolding and compile-time validation.
Plan Update Notes (2026-02-07): Reordered milestones to deliver a minimal runnable CLI at Milestone 2, and renumbered subsequent milestones accordingly to prioritize early runnable deliverables.
Plan Update Notes (2026-02-07): Completed Milestone 3 and added control/reply/mock-net modules with non-blocking unit coverage for boundary and partial-I/O cases.
Plan Update Notes (2026-02-07): Completed Milestone 4 by adding command parsing, session/auth state, and a non-blocking server tick with tests for login sequencing and second-connection `421` refusal.
Plan Update Notes (2026-02-07): Completed Milestone 5 by adding filesystem-backed navigation commands (`PWD`, `CWD`, `CDUP`), in-memory mock VFS coverage, and reply mapping tests for filesystem errors.
Plan Update Notes (2026-02-07): Completed Milestone 6 by wiring the real CLI harness (`main` + `NetStd` + rooted `VfsOs`) to the core server, fixing Zig 0.15.2 compatibility issues in argument/module wiring, and validating a manual login+PWD smoke test transcript.
Plan Update Notes (2026-02-07): Completed Milestone 7 by adding PASV session lifecycle state, `PASV` command/reply plumbing, `Net` PASV tuple formatting support, passive accept tracking, and tests for repeated PASV cleanup plus `425 Use PASV first` transfer gating.
