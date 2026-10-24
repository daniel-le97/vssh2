# vssh2 - V Language Wrapper for libssh2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A pure **V language** wrapper for the [libssh2](https://www.libssh2.org/) library. This module provides SSH2 protocol support including remote command execution, shell access, SFTP file transfers, and public key authentication — **all from V, with zero C code required from the end user**.

## Features

- ✅ **SSH Session Management** — Connect, handshake, disconnect
- ✅ **Authentication** — Password, public key (file & memory), keyboard-interactive, host-based
- ✅ **Remote Command Execution** — Run commands and capture stdout/stderr
- ✅ **Deadlock-Free Streaming** — stdout and stderr are drained together, so
  large `stderr` logs (e.g. `docker build`) stream live instead of stalling
- ✅ **Interactive Shell** — PTY allocation, shell sessions
- ✅ **SFTP** — File read/write, stat, mkdir, rmdir, unlink, rename
- ✅ **Known Hosts** — Verify server host keys
- ✅ **Keepalive** — Keep connections alive
- ✅ **Non-blocking Mode** — Async I/O support
- ✅ **Pure V API** — No C code needed by users, idiomatic V design

## Quick Setup

```bash
# Auto-detect your OS and install libssh2:
v run build.vsh setup
```

Or install manually:

| OS | Command |
|---|---|
| **macOS** | `brew install libssh2` |
| **Ubuntu/Debian** | `sudo apt-get install libssh2-1-dev` |
| **Fedora** | `sudo dnf install libssh2-devel` |
| **Arch Linux** | `sudo pacman -S libssh2` |
| **Alpine** | `sudo apk add libssh2-dev` |

## Installation

```bash
# Via vpm (install by repository, not by module name):
v install daniel-le97/vssh2

# Or clone locally:
git clone https://github.com/daniel-le97/vssh2
cd vssh2
v run build.vsh setup   # installs libssh2 if missing
v run build.vsh check   # fmt + compile + tests
```

> This repository is a **library module**, so `v build .` does not produce a
> binary. Use `v run build.vsh build` to compile the example app
> (`bin/vssh2-example`).

## Quick Start

### Password Authentication

```v
import vssh2

fn main() {
	// libssh2 initializes automatically — no init/exit needed
	session := vssh2.connect_to(vssh2.ConnectConfig{
		host: 'example.com'
		port: 22
		username: 'user'
		password: 'password'
	}) or { panic(err) }
	defer { session.close() }

	stdout, stderr := session.exec_and_read('whoami') or { panic(err) }
	println('stdout: ${stdout}')
	println('stderr: ${stderr}')
}
```

### Public Key Authentication

```v
import vssh2

fn main() {
	session := vssh2.connect_to(vssh2.ConnectConfig{
		host: 'example.com'
		username: 'user'
		privkey_file: os.expand_tilde_to_home('~/.ssh/id_rsa')
		passphrase: 'my-key-passphrase' // optional
	}) or { panic(err) }
	defer { session.close() }

	stdout, _ := session.exec_and_read('ls -la') or { panic(err) }
	println(stdout)
}
```

### Manual Step-by-Step Connection

```v
import vssh2
import net

fn main() {
	// libssh2 initializes automatically

	// 1. Create session
	session := vssh2.new_session() or { panic(err) }
	defer { session.close() }

	session.set_timeout(5000)

	// 2. Connect TCP socket
	mut socket := net.dial_tcp('example.com:22') or { panic(err) }
	defer { socket.close() or {} }

	// 3. SSH handshake (the session does NOT own this socket)
	session.connect(socket.sock.handle) or { panic(err) }

	// 4. Authenticate
	session.auth_password('user', 'password') or { panic(err) }
	if !session.is_authenticated() {
		panic('Authentication failed')
	}

	// 5. Execute command
	stdout, stderr := session.exec_and_read('uname -a') or { panic(err) }
	println('Output: ${stdout}')
	if stderr.len > 0 {
		println('Stderr: ${stderr}')
	}

	// 6. Session is auto-closed via defer
}
```

### SFTP File Transfer

```v
import vssh2

fn main() {
	session := vssh2.connect_to(vssh2.ConnectConfig{
		host: 'example.com'
		username: 'user'
		password: 'password'
	}) or { panic(err) }
	defer { session.close() }

	sftp := session.init_sftp() or { panic(err) }
	defer { sftp.close() }

	// Upload a file
	data := 'Hello from V!'.bytes()
	sftp.write_file('/remote/path/file.txt', data) or { panic(err) }

	// Download a file
	content := sftp.read_file('/remote/path/file.txt') or { panic(err) }
	println(content.bytestr())
}
```

### Interactive Shell

```v
import vssh2

fn main() {
	session := vssh2.connect_to(vssh2.ConnectConfig{
		host: 'example.com'
		username: 'user'
		password: 'password'
	}) or { panic(err) }
	defer { session.close() }

	ch := session.open_channel() or { panic(err) }
	defer { ch.close() }

	ch.request_pty('xterm') or { panic(err) }
	ch.shell() or { panic(err) }

	ch.write_string('ls -la\n') or { panic(err) }

	mut buf := []u8{len: 4096}
	for !ch.eof() {
		n := ch.read(buf) or { break }
		if n > 0 {
			print(unsafe { buf[..n].bytestr() })
		}
	}
}
```

### Streaming Command Output

`run()` runs a command and returns everything once it finishes. `start()` hands
you the running command so you can consume output as it arrives — useful for
build logs and progress bars:

```v
import vssh2
import time

fn main() {
	mut session := vssh2.connect_to(vssh2.ConnectConfig{
		host:         'example.com'
		username:     'user'
		privkey_file: os.expand_tilde_to_home('~/.ssh/id_ed25519')
	}) or { panic(err) }
	defer { session.close() }

	mut proc := session.start('docker build --progress=plain .') or { panic(err) }
	defer { proc.kill() } // no-op once finish() has run

	for {
		out := proc.pump() or { panic(err) }
		// stdout and stderr both arrive here — docker build logs go to stderr.
		print(out.stdout)
		print(out.stderr)
		if out.eof {
			break
		}
		time.sleep(100 * time.millisecond)
	}

	if code := proc.finish() or { panic(err) } {
		println('exit code: ${code}')
	}
}
```

> **V closures cannot carry state through a `fn` parameter.** V silently drops
the captured variables of a closure that is passed through a plain
`fn (...)` parameter, so this **does not** work:
>
> ```v
> mut lines := []string{}
> // BUG: `lines` never changes — the writes go to a discarded copy.
> session.run_stream('ls -la', fn [mut lines] (chunk string) { lines << chunk })
> ```
>
> `run_stream()`/`run_stream_split()` are therefore only for stateless
> callbacks. When the consumer has state, use either the `ChunkSink` interface
> (interface values keep their receiver) or `start()` + `pump()`:
>
> ```v
> struct LogFile {
> mut:
> 	file os.File
> }
>
> fn (mut l LogFile) write(chunk string) {
> 	l.file.write_string(chunk) or {}
> }
>
> // ...
> mut sink := &LogFile{ file: file }
> session.run_sink('make -j8', mut sink) or { panic(err) }
> ```

### Host Key Verification

Host key verification is **opt-in** and defaults to `.ignore`, which keeps the
historical behaviour of this module. Turn it on for anything production-like:

```v
session := vssh2.connect_to(vssh2.ConnectConfig{
	host:             'example.com'
	username:         'deploy'
	privkey_file:     '~/.ssh/id_ed25519'
	// accept_new records an unknown host key in the file (then requires it to
	// match); strict refuses unknown hosts and changed keys outright.
	host_key_mode:    .accept_new
	known_hosts_file: '~/.ssh/known_hosts' // defaults to ~/.ssh/known_hosts
}) or { panic(err) }
```

The three modes are `HostKeyMode.ignore`, `.accept_new` (OpenSSH's
`StrictHostKeyChecking=accept-new`) and `.strict`. A host whose key changed is
always rejected.

## API Overview

| Function / Method | Description |
|---|---|
| `vssh2.version()` | Get libssh2 version string |
| `vssh2.strerror(code)` | Describe a libssh2 error code |
| `vssh2.sftp_strerror(code)` | Describe a `LIBSSH2_FX_*` SFTP status code |
| `vssh2.connect_to(config)` | High-level connect, verify & authenticate |
| `session.connect(fd)` | Perform SSH handshake over your own socket |
| `session.auth_password(u, p)` | Password authentication |
| `session.auth_publickey_fromfile(...)` | Public key authentication from files |
| `session.auth_publickey_frommemory(...)` | Public key authentication from memory |
| `session.auth_list(user)` | List available auth methods |
| `session.hostkey()` | Get the server host key (data, len, type) |
| `session.verify_host_key(...)` | Check the host key against a known_hosts file |
| `session.set_blocking(bool)` | Switch between blocking and non-blocking I/O |
| `session.block_directions()` | Which direction libssh2 is waiting on |
| `session.close()` | Disconnect, free the session **and close the socket** |
| `session.run(cmd)` | Run a command, buffering the output |
| `session.run_timeout(cmd, ms)` | `run` with an inactivity timeout |
| `session.run_stream(cmd, cb)` | Run a command, forwarding output (stateless callback) |
| `session.run_sink(cmd, mut sink)` | Run a command, forwarding stateful output |
| `session.start(cmd)` | Start a command and pump its output yourself |
| `session.exec_and_read(cmd)` | Execute command and get `(stdout, stderr)` |
| `proc.pump()` / `proc.finish()` | Drain output / collect the exit code |
| `session.open_channel()` | Open a new session channel |
| `session.init_sftp()` | Initialize SFTP session |
| `session.new_knownhosts()` | Create known hosts store |
| `channel.exec(cmd)` | Execute a command |
| `channel.pump()` | Non-blocking read of both streams (deadlock-free) |
| `channel.shell()` | Start a shell |
| `ch.read(buf)` / `ch.write(data)` | Read/write channel data |
| `sftp.open(path, flags, mode)` | Open a remote file |
| `fh.read(buf)` / `fh.write(data)` | Read/write an open file (partial writes possible) |
| `fh.stat()` | fstat an open file handle |
| `sftp.read_file(path)` | Read entire remote file |
| `sftp.write_file(path, data)` | Write entire local file |
| `sftp.list_dir(path)` | List a remote directory |
| `sftp.stat(path)` | Get file attributes |
| `sftp.exists(path)` | Test whether a path exists |
| `sftp.mkdir(path, mode)` | Create directory |
| `sftp.rmdir(path)` | Remove directory |
| `sftp.unlink(path)` | Remove file |
| `sftp.rename(src, dst)` | Rename/move a remote file |
| `sftp.readlink(path)` | Resolve a symbolic link |
| `sftp.chmod(path, mode)` | Change permission bits |

## Running Tests

### Unit tests (no server required):
```bash
v test .
# or, as part of the full gate:
v run build.vsh check
```

The unit tests include a **compile-only API sweep** (`api_sweep`) that references
every public entry point. V dead-code-eliminates unused functions in an
executable, so without this gate an ABI mistake in a rarely used function
(e.g. a C macro called with the wrong arity) would only be discovered by users.
Run it for real with `SSH2_API_SWEEP=1 v test .`.

### Integration tests (requires SSH server):
```bash
# password auth
SSH2_TEST_HOST=localhost \
SSH2_TEST_PORT=22 \
SSH2_TEST_USER=testuser \
SSH2_TEST_PASS=testpass \
v test .

# public key auth (also exercises streaming, exit codes, SFTP and host keys)
SSH2_TEST_HOST=localhost \
SSH2_TEST_PORT=22 \
SSH2_TEST_USER=testuser \
SSH2_TEST_KEY=~/.ssh/id_ed25519 \
v test .

# starts a throwaway container, runs everything, then removes it
v run build.vsh docker.test
```

`SSH2_TEST_PORT` defaults to `22` when unset. Tests that need
`SSH2_TEST_KEY`/`SSH2_TEST_HOST` are skipped automatically.

The key-based tests intentionally do **not** set `pubkey_file`: libssh2 treats an
empty public key path as a filename and fails with "Unable to open public key
file", so this covers the regression where key authentication was broken when
no `.pub` file was supplied.

## Production Notes

- **Host key verification is opt-in.** The default is `HostKeyMode.ignore` for
  backwards compatibility; any deployment that talks to a network you do not
  fully control should set `.strict` (with a managed known_hosts file) or
  `.accept_new` (TOFU). A changed key is always rejected.
- **Lifecycle order.** Close channels, `ExecProcess`es and SFTP sessions
  **before** `session.close()`. Closing the session frees the libssh2 session
  that those handles belong to. `close()` is idempotent, so `defer` is safe.
- **Thread safety.** libssh2 is not thread-safe per session. Use one session per
  goroutine; do not call `send_keepalive()` from another thread.
- **Keepalive.** `configure_keepalive()` only configures the interval; libssh2
  never sends probes on its own. Call `session.send_keepalive()` periodically
  (it returns the seconds until the next probe is due).
- **`Channel.pump()` requires a non-blocking session.** `Session.start()`
  switches the session automatically; if you drive a channel manually, call
  `session.set_blocking(false)` first. In blocking mode `pump()` returns an
  error rather than silently blocking.
- **SFTP flags** follow `LIBSSH2_FXF_*`: `READ=0x01`, `WRITE=0x02`, `APPEND=0x04`,
  `CREATE=0x08`, `TRUNC=0x10`, `EXCL=0x20`.
- **Error propagation.** `run()`/`run_sink()`/`read_file()`/`write_file()` return
  an error if the transport fails mid-operation; partial output is never
  reported as success.

## Notes

- **Closure capture**: V drops the captured variables of a closure passed
  through a plain `fn (...)` parameter. Use `ChunkSink`, or `Session.start()` +
  `ExecProcess.pump()`, whenever the receiver needs to keep state.
- **Sockets**: `connect_to()` takes ownership of the TCP socket it opens and
  closes it in `close()`. `close()` is idempotent, so it is safe in `defer`.
  A file descriptor passed to `connect(fd)` yourself stays yours.
- **Output is drained multiplexed**: `run()`, `run_stream()` and `pump()` read
  stdout and stderr without blocking on either, so a command that writes a large
  log to stderr (e.g. `docker build`) can neither deadlock once the ~2 MB
  channel window fills up nor have its output truncated by a session timeout.
- **`#include` directives**: All C `#include` directives (`<libssh2.h>`,
  `<libssh2_sftp.h>`) are consolidated in `ssh2.v` only — no other file contains
  `#include`. This avoids V compiler errors about duplicate `#include` across module files.
- **Example file**: `examples/main.v` is `module main` so it does not interfere when the module is used as a dependency. Build it with `v run build.vsh build`; to run it directly use `v run examples/main.v` after installing the module (`v install daniel-le97/vssh2`).
- **Module name matches the repository**: the directory must be named `vssh2` to match `module vssh2`. `v install daniel-le97/vssh2` handles this automatically; for a local checkout, link it as `ln -sf $(pwd) ~/.vmodules/vssh2`.
- **Platforms**: POSIX (Linux/macOS). libssh2 is discovered with `pkg-config`.

## Project Structure

```
vssh2/
├── ssh2.v          # Module init, exit, error codes, core types
├── session.v       # Session management, socket ownership, keepalive
├── auth.v          # Authentication methods
├── channel.v       # Channel operations, non-blocking multiplexed pump()
├── exec.v          # Command execution: run / run_stream / run_sink / start
├── connect.v       # High-level connection helper + host key policy
├── knownhosts.v    # Known hosts verification
├── sftp.v          # SFTP file operations
├── vssh2_test.v    # Unit + integration tests (and the API compile sweep)
├── build.vsh       # Build system + dependency installer (list tasks: `v run build.vsh help`)
├── v.mod           # Module definition
├── LICENSE         # MIT license
├── README.md       # This file
└── examples/
    └── main.v      # Example usage (password & public key auth, streaming)
```

## License

MIT — see [LICENSE](LICENSE) for details.
