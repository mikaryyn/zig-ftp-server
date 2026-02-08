# zig-ftp-server

Small FTP server library and CLI runner in Zig 0.16.

The server is single-threaded, non-blocking, and advances via `tick(now_millis)`. It supports one configured user, one control session at a time, and passive mode (`PASV`) data transfers.

## Requirements

- Zig toolchain at `~/zig/zig`

## Build and test

```sh
~/zig/zig build test
~/zig/zig build
```

## Naming conventions (Zig)

Use `lowerCamelCase` for all functions, except functions that return a type (Zig), which use `PascalCase`.

## Run the CLI harness

```sh
mkdir -p /tmp/ftp-root
~/zig/zig build run -- --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test
```

CLI flags:

- `--listen <ip:port>` (default: `127.0.0.1:2121`)
- `--root <path>` (default: `.`)
- `--user <name>` (default: `test`)
- `--pass <pass>` (default: `test`)
- `--control-idle-ms <ms>` (optional)
- `--pasv-idle-ms <ms>` (optional)
- `--transfer-idle-ms <ms>` (optional)

## Supported commands

- Authentication/session: `USER`, `PASS`, `QUIT`, `NOOP`
- Basic interop: `SYST`, `TYPE`, `FEAT`
- Navigation: `PWD`, `CWD`, `CDUP`
- Passive and transfers: `PASV`, `LIST`, `RETR`, `STOR`
- File ops: `DELE`, `RNFR`, `RNTO`
- Optional implemented commands: `MKD`, `RMD`, `SIZE`, `MDTM`
- Unsupported commands return `502` (for example `PORT`)

## Limitations

- Single control session at a time; extra concurrent control connections are rejected with `421`.
- PASV-only data mode; active mode (`PORT`, `EPRT`) is not implemented.
- IPv4 PASV reply format (`227 (h1,h2,h3,h4,p1,p2)`) only.
- No TLS/FTPS.
- No resume support (`REST`) or advanced RFC extensions.

## Implementing custom Net/Fs backends

This library uses compile-time checked interfaces defined in:

- `src/ftp/interfaces_net.zig`
- `src/ftp/interfaces_fs.zig`

Instantiate the server with:

```zig
const Server = ftp.server.FtpServer(MyNet, MyFs);
```

If required declarations are missing, the comptime validators emit actionable compile errors.

### `tick()` guarantees and expectations

`tick(now_millis)` is cooperative and must not block. One tick performs bounded work:

- Accept primary control connection when idle.
- Reject extra control connections with `421` when a session is active.
- Flush pending control replies with partial-write resume.
- Progress PASV accept and active transfer state (`LIST`/`RETR`/`STOR`).
- Parse and process at most one command line per tick.

`Net` and `Fs` backends should therefore support incremental progress:

- Return `error.WouldBlock` when an operation cannot proceed immediately.
- Allow short reads/writes; the core resumes using tracked offsets.
- Keep close operations idempotent and safe to call during cleanup paths.

### Notes for `Net` implementers

- Provide control listen/accept/read/write/close operations.
- Provide PASV listen/accept/read/write/close operations.
- Surface transport failures through `interfaces_net.NetError`.
- For PASV, expose a listener address so the server can format `227 (h1,h2,h3,h4,p1,p2)`.

### Notes for `Fs` implementers

- Implement cwd lifecycle (`cwdInit`, `cwdPwd`, `cwdChange`, `cwdUp`).
- Implement transfer/file primitives used by `LIST`, `RETR`, `STOR`, `DELE`, and rename.
- Reject invalid paths robustly (including NUL bytes and root escapes for OS-backed VFS).
- Map backend errors to the defined `FsError` set so reply mapping stays deterministic.
