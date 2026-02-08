# FTP Server Improvements: Structured Logs, `NLST`, and Input Limits

This ExecPlan is a living document. The sections `Progress`, `Surprises & Discoveries`, `Decision Log`, and `Outcomes & Retrospective` must be kept up to date as work proceeds.

No `PLANS.md` file exists in this repository at the time this plan is written, so this document is self-contained and defines its own execution details.

## Purpose / Big Picture

After this change, operators can read stable, machine-parseable log lines for connection, authentication, and transfer activity; FTP clients that use name-only listings can use `NLST`; and command/input validation becomes stricter and more predictable under malformed or oversized inputs. The result remains intentionally small: one server loop, fixed buffers, and no new required dependencies.

A human can observe success by running the CLI server, authenticating with a client, running `NLST`, and seeing structured one-line logs that include consistent key/value fields and clear outcomes.

## Progress

- [x] (2026-02-07 23:48Z) Created initial ExecPlan covering structured logs, `NLST`, and tightened input limits with milestone-level validation.
- [ ] Implement structured logging in core and CLI without introducing heap requirements in the protocol core.
- [ ] Implement `NLST` as a PASV transfer command with deterministic CRLF output and partial-write resume.
- [ ] Tighten command and argument validation rules and add focused regression tests.
- [ ] Run full test/build/manual acceptance sequence and update this plan’s living sections with evidence.

## Surprises & Discoveries

- Observation: `LIST` transfer behavior is already centralized in `src/ftp/server.zig` and `src/ftp/transfer.zig`, which makes `NLST` straightforward to add as a second listing mode rather than a second transfer engine.
  Evidence: `ListTransfer` and `driveListTransfer` currently control accept-gating (`150`), line buffering, partial writes, and `226` completion.

- Observation: path length checking currently reuses `session.rename_from.len`, which equals `limits.path_max`, but the validation intent is not explicit.
  Evidence: `validatePathArg` checks `if (path.len > self.session.rename_from.len)` in `src/ftp/server.zig`.

## Decision Log

- Decision: Structured logging will use an optional callback in `Config` (event + fields) instead of hardcoding `std.log` in the core.
  Rationale: Keeps `src/ftp/server.zig` embeddable and testable while allowing the CLI to format logs for humans or machines.
  Date/Author: 2026-02-07 / Codex

- Decision: `NLST` will reuse the existing listing transfer state machine with a mode switch (`detailed` vs `names_only`) instead of a second transfer path.
  Rationale: Reduces code size and risk while preserving proven non-blocking transfer sequencing.
  Date/Author: 2026-02-07 / Codex

- Decision: Input tightening will be strict but minimal: reject unexpected arguments for arg-less commands, reject control bytes in path/user/pass arguments, and enforce explicit maxima for username/password length.
  Rationale: Improves robustness with small code changes and no protocol-scope expansion.
  Date/Author: 2026-02-07 / Codex

- Decision: `NLST` will fail the transfer (reply `451`) if a directory entry name contains bytes that would break the line protocol (`\r`, `\n`, or NUL).
  Rationale: Prevents CRLF injection and keeps listing output deterministic even with hostile or corrupt directory entries.
  Date/Author: 2026-02-07 / Codex

## Outcomes & Retrospective

At plan creation time, no implementation work from this document has been applied yet. The expected outcome is improved observability, broader baseline FTP compatibility (`NLST`), and stricter, deterministic parsing behavior without changing the single-session/PASV-only architecture.

## Context and Orientation

The FTP protocol core is implemented in `src/ftp/server.zig` and currently dispatches commands parsed by `src/ftp/commands.zig`. Transfer formatting helpers live in `src/ftp/transfer.zig`. Configuration and shared types are in `src/ftp/misc.zig`, while limits are in `src/ftp/limits.zig`. The runnable CLI is `src/cli/main.zig`, with network and filesystem adapters in `src/cli/net_std.zig` and `src/cli/vfs_os.zig`.

In this repository, “structured log” means a single line with stable keys, such as `event=auth_ok user=test remote=127.0.0.1:54321`, emitted at important lifecycle points. “Input limits” means explicit maximum lengths and byte-validity checks at parse/dispatch boundaries so malformed commands are rejected with deterministic FTP replies (`500`, `501`, or `553`) rather than leaking inconsistent behavior into the filesystem/network layers.

The server is intentionally cooperative and non-blocking. Any new behavior in this plan must preserve `tick(now_millis)` bounded work and existing partial I/O resume semantics.

## Plan of Work

This plan is broken into three implementation milestones and one final acceptance milestone. Each milestone must preserve the current non-blocking, single-threaded behavior: `tick(now_millis)` does bounded work, network and filesystem operations surface `error.WouldBlock`, and partial I/O is resumed on later ticks.

### Milestone 1: Structured Logs (Core Hook + CLI Formatter)

At the end of this milestone, the server emits stable one-line key/value records for major lifecycle events without requiring heap allocation in the protocol core. The CLI prints these lines to stdout/stderr using `std.log`, but embedders can provide their own callback.

Edits to implement:

1. Add a minimal logger interface to config.

   In `src/ftp/misc.zig`:

   - Add:

         pub const LogLevel = enum { debug, info, warn, err };

         pub const Logger = struct {
             ctx: ?*anyopaque = null,
             write: *const fn (ctx: ?*anyopaque, level: LogLevel, line: []const u8) void,
         };

   - Add `logger: ?Logger = null` to `pub const Config`.

   Rule: the logger callback must treat `line` as ephemeral. The core will format into `storage.scratch` and the slice is only valid for the duration of the callback call.

2. Add formatting helpers and emission points in the core.

   In `src/ftp/server.zig`:

   - Add `fn logLine(self: *Self, level: misc.LogLevel, line: []const u8) void` to call `self.config.logger` if present.
   - Add `fn logFmt(self: *Self, level: misc.LogLevel, comptime fmt: []const u8, args: anytype) void` that uses `std.fmt.bufPrint(self.storage.scratch, ...)` and truncates on failure (for example, by emitting only `event=log_oom` or by best-effort emitting a prefix).

   Emit logs at these exact points (minimum set):

   - `acceptPrimaryConn` success: `event=conn_accept`.
   - `rejectExtraConn` path: `event=conn_reject reason=too_many_users`.
   - When a complete command line is parsed in `tick`: `event=cmd cmd=<CMD> arg_len=<n>`.
     Note: `<CMD>` should be the raw command token as seen on the wire, uppercased for stability. `arg_len` is `parsed.argument.len`.
   - On successful authentication transition (after PASS match): `event=auth_ok user=<configured user>`.
   - On auth failure: `event=auth_fail reason=<bad_user|bad_pass|missing_user|missing_pass|invalid_bytes|too_long>`.
   - On transfer start (when the server queues `150` for a transfer): `event=transfer_start cmd=<LIST|NLST|RETR|STOR>`.
   - On transfer completion (when the server queues `226`): `event=transfer_done cmd=<...> bytes=<n>`.
   - On timeout-triggered closes: `event=timeout which=<control|pasv|transfer>`.

   Byte counting:

   - Add byte counters to `src/ftp/transfer.zig` state structs (`ListTransfer`, `RetrTransfer`, `StorTransfer`), incremented on successful data socket reads/writes. Log `bytes=` from the appropriate counter when completing the transfer.

3. Add a CLI logger implementation.

   In `src/cli/main.zig`:

   - Create a small logger function `fn cliLog(ctx: ?*anyopaque, level: ftp.misc.LogLevel, line: []const u8) void` that maps `LogLevel` to `std.log` levels and writes exactly one line (no extra formatting beyond `line`).
   - Pass `.logger = .{ .ctx = null, .write = cliLog }` in the `config` passed to `Server.initNoHeap(...)`.

4. Add tests for log emission.

   In `src/ftp/server.zig` tests:

   - Add a `TestLogger` with a fixed buffer and a counter, plus a callback that copies the last log line into the buffer (truncate on overflow).
   - Add tests that prove at least:
     - Successful login emits a line containing `event=auth_ok`.
     - Bad password emits a line containing `event=auth_fail`.
     - Concurrent connection rejection emits `event=conn_reject`.

Milestone 1 acceptance:

- `~/zig/zig build test` passes.
- Running `./zig-out/bin/ftp-server ...` and logging in produces at least one `event=cmd` line and one `event=auth_ok` line in logs.

### Milestone 2: `NLST` Support (Names-Only Listing)

At the end of this milestone, `NLST` behaves like `LIST` with a different data payload: it streams only entry names, one per `\r\n`-terminated line. It still requires auth and PASV and still waits for the data connection accept before sending `150`.

Edits to implement:

1. Parse and dispatch the command.

   In `src/ftp/commands.zig`:

   - Add `nlst` to `pub const Command`.
   - Add parse mapping for `NLST`.
   - Add tests for `parse("NLST")` and `parse("NLST subdir")`.

   In `src/ftp/server.zig`:

   - Add `.nlst => try self.handleNlst(parsed.argument),` in the authed command switch.

2. Add a list mode to the existing list transfer.

   In `src/ftp/transfer.zig`:

   - Add `pub const ListMode = enum { detailed, names_only };`
   - Extend `ListTransfer` to include `mode: ListMode = .detailed`.

3. Add NLST formatting helper.

   In `src/ftp/transfer.zig`:

   - Add `pub fn formatNlstEntry(out: []u8, entry: interfaces_fs.DirEntry) ![]const u8`.
   - Reject `entry.name` containing `\r`, `\n`, or NUL (return an error).
   - Write `<name>\r\n` into `out` and return the slice.
   - Add a unit test that the output ends with `\r\n` and that an entry name containing `\n` fails.

4. Implement `handleNlst` and stream names.

   In `src/ftp/server.zig`:

   - Implement `handleNlst` by mirroring `handleList`:
     - Require PASV not idle (`425 Use PASV first`).
     - Trim optional arg; validate with `validatePathArg` if non-empty.
     - Open dir iter via `Fs.dirOpen` with `null` for current dir or the optional arg.
     - Initialize `list_transfer` with `.state = .list_waiting_accept` and `.mode = .names_only`.

   In `driveListTransfer`:

   - When producing a line from a `DirEntry`, select between `formatListEntry` and `formatNlstEntry` based on `list_transfer.mode`.
   - If `formatNlstEntry` errors due to invalid name bytes, abort the transfer with:
     - reply `451 Requested action aborted: local error in processing`
     - close iter and passive resources (same cleanup rule as existing list abort paths)

Milestone 2 acceptance:

- `~/zig/zig build test` passes.
- Manual check: `curl --silent --show-error --ftp-pasv --user test:test --list-only ftp://127.0.0.1:2121/ -o /tmp/list_names.txt` succeeds, and `/tmp/list_names.txt` contains `a.txt` without detailed permission/size fields.

### Milestone 3: Tighten Input Limits (Deterministic Rejection)

At the end of this milestone, invalid inputs are rejected earlier and deterministically. This is intentionally conservative: if a client sends unexpected arguments to arg-less commands or includes control bytes in sensitive arguments, the server responds with `501` or `553` rather than passing it further into core/VFS logic.

Edits to implement:

1. Add explicit maxima for `USER` and `PASS` arguments.

   In `src/ftp/limits.zig`, add:

   - `pub const user_arg_max: usize = 64;`
   - `pub const pass_arg_max: usize = 64;`

2. Enforce `USER`/`PASS` argument rules.

   In `src/ftp/server.zig` (inside `handlePreAuth`):

   - Replace ad-hoc missing-argument checks with:
     - reject empty -> `501 Missing username` / `501 Missing password` (existing messages are fine)
     - reject `len > limits.user_arg_max` or `limits.pass_arg_max` -> `501 Syntax error in parameters or arguments`
     - reject NUL or any control byte (`< 0x20`) or DEL (`0x7f`) -> `501 Syntax error in parameters or arguments`

3. Tighten path validation for all path-based commands.

   In `src/ftp/server.zig`:

   - Update `validatePathArg` to:
     - check length against `limits.path_max` explicitly
     - reject NUL
     - reject any control byte (`< 0x20`) and DEL (`0x7f`)
   - Keep the reply for invalid paths as the existing `553` text.

4. Reject extra arguments for arg-less commands.

   In `src/ftp/server.zig`:

   - Add helper `fn requireNoArg(self: *Self, arg: []const u8) interfaces_net.NetError!bool`:
     - `trim` spaces; if any bytes remain, queue `501 Syntax error in parameters or arguments` and return false.
   - Apply it before executing:
     - `NOOP`, `SYST`, `FEAT`, `PASV`, `PWD`, `CDUP`, `QUIT`
   - Leave behavior unchanged for commands that already parse arguments (`TYPE`, `CWD`, `LIST`, `NLST`, `RETR`, `STOR`, `DELE`, `RNFR`, `RNTO`, `MKD`, `RMD`, `SIZE`, `MDTM`).

5. Add regression tests for tightened validation.

   In `src/ftp/server.zig` tests, add at least:

   - `NOOP extra` returns `501`.
   - `PASV extra` returns `501`.
   - `USER` over `limits.user_arg_max` returns `501`.
   - A path containing `\x01` returns `553` for a path-based command (pick one: `CWD` is simple).

Milestone 3 acceptance:

- `~/zig/zig build test` passes.
- Manual check: `printf "USER test\r\nPASS test\r\nNOOP extra\r\nQUIT\r\n" | nc 127.0.0.1 2121` includes a `501` reply after `NOOP extra`.

### Milestone 4: Final Acceptance Run-Through

This milestone is a human-facing verification run that exercises:

- logs appear and are single-line `event=...` kv records,
- `LIST` and `NLST` both succeed (different outputs),
- tightened validation rejects known-bad inputs with deterministic reply codes,
- existing acceptance behavior remains intact (auth, transfers, file ops, `421` second connection).

## Concrete Steps

Run all commands from `/Users/mika/code/paperportal/modules/zig-ftp-server`.

Milestone 1:

    ~/zig/zig fmt src/**/*.zig build.zig
    ~/zig/zig build test

Milestone 2:

    ~/zig/zig fmt src/**/*.zig build.zig
    ~/zig/zig build test

Milestone 3:

    ~/zig/zig fmt src/**/*.zig build.zig
    ~/zig/zig build test

Milestone 4:

    mkdir -p /tmp/ftp-root-plan
    printf "alpha\n" > /tmp/ftp-root-plan/a.txt
    ~/zig/zig build
    ./zig-out/bin/ftp-server --listen 127.0.0.1:2121 --root /tmp/ftp-root-plan --user test --pass test > /tmp/ftp-server.log 2>&1

In another shell:

    curl --silent --show-error --ftp-pasv --user test:test ftp://127.0.0.1:2121/ -o /tmp/list_full.txt
    curl --silent --show-error --ftp-pasv --user test:test --list-only ftp://127.0.0.1:2121/ -o /tmp/list_names.txt
    printf "USER test\r\nPASS test\r\nNOOP extra\r\nQUIT\r\n" | nc 127.0.0.1 2121
    rg -n "event=" /tmp/ftp-server.log

Expected result: `/tmp/list_names.txt` contains only names (for example `a.txt`), and `NOOP extra` returns `501`. Server logs show structured `event=...` lines for commands and auth.

## Validation and Acceptance

Acceptance requires all of the following observable outcomes.

`~/zig/zig build test` passes with new coverage for:

- structured logging callback invocation for success and failure paths,
- `NLST` command parsing and transfer sequencing,
- tightened input limit checks for arg-less commands receiving extra parameters,
- rejection of invalid bytes and overlong arguments.

`~/zig/zig build` succeeds and the CLI can run and serve both listing styles:

- `LIST` still returns detailed lines in existing format,
- `NLST` returns only entry names, one per CRLF line,
- PASV and single-session behavior remain unchanged.

Manual behavior checks:

- bad login emits a structured auth-failure event and returns `530`,
- good login emits auth-success event and allows transfers,
- `curl --list-only` succeeds and outputs name-only listing,
- malformed input (`NOOP extra`, path with control byte in tests) is rejected with intended reply codes.

## Idempotence and Recovery

All implementation steps are additive and safe to rerun. Running `~/zig/zig fmt` repeatedly is idempotent. If tests fail mid-way, fix code and rerun `~/zig/zig build test` until green. Manual acceptance uses `/tmp/ftp-root-plan`, which can be removed and recreated without affecting repository state.

If runtime state becomes unclear during manual checks, stop the CLI process, clear temporary files under `/tmp/ftp-root-plan`, and start again. No migration or destructive repository operation is required.

## Artifacts and Notes

Keep concise evidence snippets in this section as work proceeds. Add short transcripts like:

    220 FTP Server Ready
    331 User name okay, need password
    230 User logged in
    150 Opening data connection
    226 Closing data connection

And log examples like:

    info: event=conn_accept remote=127.0.0.1:54712
    info: event=cmd cmd=USER arg_len=4
    info: event=auth_ok user=test
    info: event=transfer_done cmd=NLST bytes=6

## Interfaces and Dependencies

This work uses only existing Zig standard library and existing repository modules.

`src/ftp/misc.zig` should define stable logging interface types used by `Config`, such as:

    pub const LogLevel = enum { debug, info, warn, err };
    pub const Logger = struct {
        ctx: ?*anyopaque = null,
        write: *const fn (ctx: ?*anyopaque, level: LogLevel, line: []const u8) void,
    };

`src/ftp/server.zig` must remain generic over `Net` and `Fs` and must not require allocator use to emit logs. `src/ftp/commands.zig` must include `nlst` in `Command` and parser mapping. `src/ftp/transfer.zig` should expose a dedicated helper for NLST line formatting (name + CRLF). `src/cli/main.zig` should provide one default logger callback for human-readable structured output.

No new third-party dependencies are allowed.

Plan Update Notes (2026-02-07): Expanded milestones 1-3 with concrete file-level edits, exact event/field requirements for structured logs, and deterministic validation rules.
