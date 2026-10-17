module ssh2

import net
import os

// ------------------------------------------------------------------
// High-level convenience: connect to a remote host
// ------------------------------------------------------------------
// This file provides a convenient way to establish an SSH connection
// without needing to deal with raw sockets. Uses V's built-in `net` module.

// HostKeyMode selects how the remote host key is verified during the handshake.
pub enum HostKeyMode {
	// ignore skips verification entirely. This matches libssh2's raw behaviour
	// and the historical default of this module, but it offers no protection
	// against man-in-the-middle attacks.
	ignore
	// accept_new verifies the key against the known_hosts file and records
	// unknown keys, like OpenSSH's `StrictHostKeyChecking=accept-new`.
	accept_new
	// strict verifies the key against the known_hosts file and refuses to
	// connect when the host is unknown or its key has changed.
	strict
}

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
	// host_key_mode controls host key verification. `.ignore` (the default)
	// preserves the historical behaviour of this module; set `.accept_new` or
	// `.strict` to verify the server identity.
	host_key_mode HostKeyMode = .ignore
	// known_hosts_file is the OpenSSH-format known_hosts file used when
	// host_key_mode is not `.ignore`. Defaults to `~/.ssh/known_hosts`.
	known_hosts_file string
}

// known_hosts_path resolves the known_hosts file to use for verification.
fn (config ConnectConfig) known_hosts_path() string {
	if config.known_hosts_file.len > 0 {
		return config.known_hosts_file
	}
	home := os.home_dir()
	if home.len == 0 {
		return ''
	}
	return os.join_path(home, '.ssh', 'known_hosts')
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
	if config.username.len == 0 {
		return error('SSH username is required')
	}

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
	socket := net.dial_tcp(address) or {
		session.close()
		return error('TCP connection to ${address} failed: ${err}')
	}

	// From here on the session owns the socket and closes it in close().
	session.own_socket = socket
	session.socket_fd = socket.sock.handle

	// Perform SSH handshake
	session.connect(session.socket_fd) or {
		session.close()
		return error('SSH handshake with ${address} failed: ${err}')
	}

	// Optionally verify the identity of the server.
	verify_host(session, config) or {
		session.close()
		return err
	}

	// Authenticate
	authenticate(session, config) or {
		session.close()
		return error('SSH authentication as ${config.username}@${address} failed: ${err}')
	}

	if !session.is_authenticated() {
		session.close()
		return error('SSH authentication as ${config.username}@${address} failed')
	}

	// Configure keepalive if requested
	if config.keepalive_interval > 0 {
		session.configure_keepalive(true, config.keepalive_interval)
	}

	return session
}

// authenticate runs the configured authentication method: a password when one
// is set, otherwise public key authentication.
fn authenticate(session &Session, config ConnectConfig) ! {
	if config.password.len > 0 {
		return session.auth_password(config.username, config.password)
	}
	if config.privkey_file.len > 0 {
		// NOTE: an empty `pubkey_file` must be passed through as NULL. libssh2
		// treats a non-NULL empty string as a filename and fails with
		// "Unable to open public key file" (see auth.v).
		return session.auth_publickey_fromfile(config.username, config.pubkey_file,
			config.privkey_file, config.passphrase)
	}
	return error('No authentication method provided (set `password` or `privkey_file`)')
}

// verify_host applies `config.host_key_mode` to the host key the server sent.
fn verify_host(session &Session, config ConnectConfig) ! {
	if config.host_key_mode == .ignore {
		return
	}
	if config.host_key_mode == .strict && config.known_hosts_file.len == 0 {
		// Verification against the default file is still fine; only complain when
		// there is nowhere to read keys from at all.
		if config.known_hosts_path().len == 0 {
			return error('Host key verification is enabled but no known_hosts file could be resolved')
		}
	}
	path := config.known_hosts_path()
	result := session.verify_host_key(config.host, config.port, path,
		config.host_key_mode == .accept_new)!
	host_port := '${config.host}:${config.port}'
	match result {
		.match {
			return
		}
		.mismatch {
			return error('Host key for ${host_port} has CHANGED (possible man-in-the-middle); expected key found in ${path}')
		}
		.not_found {
			return error('Unknown host key for ${host_port}; add it to ${path} or use HostKeyMode.accept_new')
		}
		.failure {
			return error('Host key verification for ${host_port} failed')
		}
	}
}
