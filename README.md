# ssh2 - V Language Wrapper for libssh2

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A pure **V language** wrapper for the [libssh2](https://www.libssh2.org/) library. This module provides SSH2 protocol support including remote command execution, shell access, SFTP file transfers, and public key authentication — **all from V, with zero C code required from the end user**.

## Features

- ✅ **SSH Session Management** — Connect, handshake, disconnect
- ✅ **Authentication** — Password, public key (file & memory), keyboard-interactive, host-based
- ✅ **Remote Command Execution** — Run commands and capture stdout/stderr
- ✅ **Interactive Shell** — PTY allocation, shell sessions
- ✅ **SFTP** — File read/write, stat, mkdir, rmdir, unlink, rename
- ✅ **Known Hosts** — Verify server host keys
- ✅ **Keepalive** — Keep connections alive
- ✅ **Non-blocking Mode** — Async I/O support
- ✅ **Pure V API** — No C code needed by users, idiomatic V design

## Quick Setup

```bash
# Auto-detect your OS and install libssh2:
v run setup.vsh
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
# Via vpm:
v install ssh2

# Or clone locally:
git clone https://github.com/vssh2/vssh2
cd vssh2
v run setup.vsh   # installs libssh2 if missing
v build .
```

## Quick Start

### Password Authentication

```v
import ssh2

fn main() {
	// libssh2 initializes automatically — no init/exit needed
	session := ssh2.connect_to(ssh2.ConnectConfig{
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
import ssh2

fn main() {
	session := ssh2.connect_to(ssh2.ConnectConfig{
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
import ssh2
import net

fn main() {
	// libssh2 initializes automatically

	// 1. Create session
	session := ssh2.new_session() or { panic(err) }
	defer { session.close() }

	session.set_timeout(5000)

	// 2. Connect TCP socket
	mut socket := net.dial_tcp('example.com:22') or { panic(err) }

	// 3. SSH handshake
	session.connect(socket.sock.fd) or { panic(err) }

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
import ssh2

fn main() {
	session := ssh2.connect_to(ssh2.ConnectConfig{
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
import ssh2

fn main() {
	session := ssh2.connect_to(ssh2.ConnectConfig{
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

## API Overview

| Function / Method | Description |
|---|---|
| `ssh2.version()` | Get libssh2 version string |
| `ssh2.new_session()` | Create a new SSH session |
| `ssh2.connect_to(config)` | High-level connect & authenticate |
| `session.connect(fd)` | Perform SSH handshake |
| `session.auth_password(u, p)` | Password authentication |
| `session.auth_publickey_fromfile(...)` | Public key authentication from files |
| `session.auth_publickey_frommemory(...)` | Public key authentication from memory |
| `session.auth_list(user)` | List available auth methods |
| `session.open_channel()` | Open a new session channel |
| `session.exec_and_read(cmd)` | Execute command and get output |
| `session.init_sftp()` | Initialize SFTP session |
| `session.new_knownhosts()` | Create known hosts store |
| `channel.exec(cmd)` | Execute a command |
| `channel.shell()` | Start a shell |
| `ch.read(buf)` / `ch.write(data)` | Read/write channel data |
| `sftp.open(path, flags, mode)` | Open a remote file |
| `sftp.read_file(path)` | Read entire remote file |
| `sftp.write_file(path, data)` | Write entire local file |
| `sftp.stat(path)` | Get file attributes |
| `sftp.mkdir(path, mode)` | Create directory |
| `sftp.rmdir(path)` | Remove directory |
| `sftp.unlink(path)` | Remove file |

## Running Tests

### Unit tests (no server required):
```bash
v test .
```

### Integration tests (requires SSH server):
```bash
SSH2_TEST_HOST=localhost \
SSH2_TEST_PORT=22 \
SSH2_TEST_USER=testuser \
SSH2_TEST_PASS=testpass \
v test .
```

## Project Structure

```
ssh2/
├── ssh2.v          # Module init, exit, core types
├── session.v       # Session management
├── auth.v          # Authentication methods
├── channel.v       # Channel operations
├── connect.v       # High-level connection helper
├── knownhosts.v    # Known hosts verification
├── sftp.v          # SFTP file operations
├── ssh2_test.v     # Tests
├── build.vsh       # Build system (list tasks: `v run build.vsh --tasks`)
├── setup.vsh       # Dependency installer: `v run setup.vsh`
├── v.mod           # Module definition
├── LICENSE          # MIT license
├── README.md       # This file
└── main.v          # Example usage
```

## License

MIT — see [LICENSE](LICENSE) for details.
