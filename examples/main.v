module main

import ssh2
import os
import time

// Example usage of the ssh2 V wrapper.
// This demonstrates connecting to an SSH server, authenticating, and running commands.
//
// To run this example:
//   SSH_HOST=example.com SSH_USER=user SSH_PASS=password v run .
//
// Note: libssh2 initializes automatically on import — no manual init/exit needed.
fn main() {
	println('Using libssh2 version: ${ssh2.version()}')

	// Get connection details from environment (or use defaults for demo)
	host := os.getenv('SSH_HOST')
	if host == '' {
		println('Set SSH_HOST, SSH_USER, and SSH_PASS environment variables to run this example.')
		println('Example: SSH_HOST=example.com SSH_USER=user SSH_PASS=password v run .')
		return
	}

	user := os.getenv('SSH_USER')
	pass := os.getenv('SSH_PASS')

	// Connect, handshake, and authenticate in one call
	session := ssh2.connect_to(ssh2.ConnectConfig{
		host:       host
		port:       22
		username:   user
		password:   pass
		timeout_ms: 10000
	}) or { panic(err) }
	defer { session.close() }

	println('Connected and authenticated!')

	// Run a command and capture output
	stdout, stderr := session.exec_and_read('uname -a') or { panic(err) }
	println('=== Command output ===')
	println(stdout)
	if stderr.len > 0 {
		println('=== Stderr ===')
		println(stderr)
	}

	// Get exit status from last command
	println('Done!')

	// Stream a command's output live. `start()` + `pump()` keeps all state in
	// this function — a capturing closure passed through a `fn` parameter would
	// silently lose it (see the README).
	println('=== Streaming ===')
	mut proc := session.start('for i in 1 2 3; do echo line \\$i 1>&2; sleep 0.2; done') or {
		panic(err)
	}
	for {
		out := proc.pump() or { panic(err) }
		print(out.stdout)
		print(out.stderr)
		if out.eof {
			break
		}
		time.sleep(50 * time.millisecond)
	}
	code := proc.finish() or { panic(err) }
	println('streamed command exit code: ${code}')
}
