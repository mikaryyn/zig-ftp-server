# zig-ftp-server

A small, embeddable FTP **server** library written in Zig. The library is single-threaded and progresses via a cooperative `tick()` loop with non-blocking I/O. It supports one control session at a time, a single configured user, and passive-mode-only (`PASV`) data connections. The long-term goal is a basic but practically usable FTP server with streaming transfers and small fixed buffers.

See the design plan at `docs/ftp_server_plan.md` and the protocol/spec details at `docs/ftp_server_spec.md`.

## Requirements

- Zig 0.16 (the project targets Zig 0.16 APIs).

## Tests

Run unit tests from the repo root:

```sh
zig build test
```

## CLI App

The CLI harness (used as a runnable demo and smoke-test) is planned for Milestone 5 and is not yet present in this repository. Once implemented, it will build an `ftp-server` executable and support a command line like:

```sh
zig build
zig build run -- --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test
```

Example manual smoke test (once the CLI exists):

```sh
printf "USER test\r\nPASS test\r\nPWD\r\nQUIT\r\n" | nc 127.0.0.1 2121
```

If you need the CLI sooner, I can implement Milestone 5 after the control-channel and state machine milestones are complete.
