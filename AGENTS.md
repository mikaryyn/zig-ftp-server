# Repository Guidelines
Always use Zig executable and standard libraries at `~/zig/zig`.

## Project Structure & Module Organization
Core library code lives in `src/ftp/` (protocol parsing, session state, control/data flow, replies, and mocks).
The module entrypoint is `src/root.zig`.
CLI/runtime wiring is in `src/cli/` (`main.zig`, OS VFS, std-net adapters).
Design and protocol notes are in `docs/`.

## Build, Test, and Development Commands
- `~/zig/zig build test`: Runs all unit tests (`std.testing`) across the module. Use this as the main validation command.
- `~/zig/zig build`: Builds and installs `ftp-server`.
- `~/zig/zig build run -- --listen 127.0.0.1:2121 --root /tmp/ftp-root --user test --pass test`: Runs the CLI with sample args.
- `~/zig/zig fmt src/**/*.zig build.zig`: Formats source files.

## Coding Style & Naming Conventions
Use Zig 0.16 APIs and keep code `~/zig/zig fmt` clean before opening a PR.
Follow existing naming:
- Types and public structs/enums: `UpperCamelCase` (for example `Session`, `TransferType`).
- Functions, locals, file names: `lower_snake_case` (for example `parse_command`, `mock_vfs.zig`).
- Keep modules focused by concern (`commands`, `control`, `transfer`, `replies`).

## Testing Guidelines
Place tests in the same `.zig` file as the code under test using `test "..." { ... }`.
Name tests by behavior, not implementation details (for example `test "server requires PASV before LIST RETR STOR"`).
Prefer deterministic tests using `mock_net` and `mock_vfs` over real sockets/filesystem.
