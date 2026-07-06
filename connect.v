module ssh2

import net

#include <libssh2.h>

// ------------------------------------------------------------------
// High-level convenience: connect to a remote host
// ------------------------------------------------------------------
// This file provides a convenient way to establish an SSH connection
// without needing to deal with raw sockets. Uses V's built-in `net` module.

// ConnectConfig holds the configuration for an SSH connection.
pub struct ConnectConfig {
pub:
	host               string = 'localhost'
	port               int    = 22
	username           string
	password           string
	privkey_file       string // path to private key file
	pubkey_file        string // path to public key file (optional when using privkey)
	passphrase         string // passphrase for private key
	timeout_ms         int = 10000
	keepalive_interval int // 0 = disabled
}

// connect_to establishes an SSH connection to a remote host using the
// provided configuration. It handles:
//   - TCP connection to the host:port
//   - SSH handshake
//   - Authentication (password or public key)
//
// Returns an initialized Session that is authenticated and ready.
//
// Example:
// ```v
// import ssh2
//
// fn main() {
//     // libssh2 initializes automatically on import
//     session := ssh2.connect_to(ssh2.ConnectConfig{
//         host: 'example.com'
//         username: 'user'
//         password: 'password'
//     }) or { panic(err) }
//     defer { session.close() }
// }
// ```
pub fn connect_to(config ConnectConfig) !&Session {
	// Create a new session
	mut session := new_session()!

	// Set timeout
	if config.timeout_ms > 0 {
		session.set_timeout(config.timeout_ms)
	}

	// Set blocking mode
	session.set_blocking(true)

	// Connect the TCP socket
	address := '${config.host}:${config.port}'
	mut socket := net.dial_tcp(address) or {
		session.close()
		return err
	}
	fd := socket.sock.Socket.handle

	// Perform SSH handshake
	session.connect(fd) or {
		session.close()
		return err
	}

	// Authenticate
	mut authenticated := false

	if config.password.len > 0 {
		session.auth_password(config.username, config.password) or {
			session.close()
			return err
		}
		authenticated = true
	} else if config.privkey_file.len > 0 {
		session.auth_publickey_fromfile(config.username, config.pubkey_file, config.privkey_file,
			config.passphrase) or {
			session.close()
			return err
		}
		authenticated = true
	}

	if !authenticated {
		session.close()
		return error('No authentication method provided (password or private key)')
	}

	// Verify authentication
	if !session.is_authenticated() {
		session.close()
		return error('Authentication failed')
	}

	// Configure keepalive if requested
	if config.keepalive_interval > 0 {
		session.configure_keepalive(true, config.keepalive_interval)
	}

	return session
}
