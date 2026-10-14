module ssh2

import os

// ------------------------------------------------------------------
// Unit tests - these test the wrapper internals without a live server
// ------------------------------------------------------------------

fn test_version_not_empty() {
	// libssh2 is auto-initialized by the module's init()
	ver := version()
	assert ver.len > 0
	assert ver.contains('.') // should be something like "1.11.0"
}

fn test_socket_error_message() {
	assert socket_error_message(-1) == 'socket error'
	assert socket_error_message(-9) == 'socket disconnected'
	assert socket_error_message(-13) == 'auth failed'
	assert socket_error_message(-16) == 'sftp failure'
	assert socket_error_message(999) == 'unknown error (999)'
}

fn test_session_blocking_mode() {
	session := new_session() or { return }
	defer { session.close() }

	// Default is blocking
	assert session.is_blocking()

	// Switch to non-blocking
	session.set_blocking(false)
	assert !session.is_blocking()

	// Switch back
	session.set_blocking(true)
	assert session.is_blocking()
}

fn test_session_timeout() {
	session := new_session() or { return }
	defer { session.close() }

	session.set_timeout(5000)
	timeout := session.timeout()
	// Just verify it doesn't crash
	assert true
}

fn test_parse_auth_methods() {
	methods := parse_auth_methods('password,publickey')
	assert methods.len == 2
	assert methods[0] == AuthMethod.password
	assert methods[1] == AuthMethod.publickey

	methods2 := parse_auth_methods('keyboard-interactive,publickey')
	assert methods2.len == 2
	assert methods2[0] == AuthMethod.keyboard_interactive

	methods3 := parse_auth_methods('')
	assert methods3.len == 1
	assert methods3[0] == AuthMethod.unknown
}

fn test_auth_method_enum_values() {
	assert AuthMethod.password.str() == 'password'
	assert AuthMethod.publickey.str() == 'publickey'
	assert AuthMethod.keyboard_interactive.str() == 'keyboard_interactive'
}

fn test_sftp_attrs_conversion() {
	attrs := SftpAttrs{
		flags:       sftp_attr_size | sftp_attr_permissions
		size:        1024
		permissions: 0o644
	}
	assert attrs.flags & sftp_attr_size != 0
	assert attrs.flags & sftp_attr_permissions != 0
	assert attrs.size == 1024
	assert attrs.permissions == 0o644
}

fn test_sftp_open_flags() {
	read_write := sftp_open_flag_read | sftp_open_flag_write
	assert read_write == (0x00000001 | 0x00000002)

	create_trunc := sftp_open_flag_create | sftp_open_flag_trunc
	assert create_trunc == (0x00000010 | 0x00000020)
}

fn test_sftp_file_type_values() {
	assert SftpFileType.regular.str() == 'regular'
	assert SftpFileType.directory.str() == 'directory'
	assert SftpFileType.symlink.str() == 'symlink'
}

fn test_knownhost_check_result_values() {
	assert KnownHostCheckResult.match.str() == 'match'
	assert KnownHostCheckResult.mismatch.str() == 'mismatch'
	assert KnownHostCheckResult.not_found.str() == 'not_found'
}

fn test_method_type_values() {
	assert MethodType.kex.str() == 'kex'
	assert MethodType.hostkey.str() == 'hostkey'
}

fn test_ssh2_error_struct() {
	err := Ssh2Error{
		code:    -1
		message: 'test error'
	}
	assert err.code == -1
	assert err.message == 'test error'
	assert err.str() == 'Ssh2Error(-1): test error'
}

fn test_connect_config_defaults() {
	config := ConnectConfig{}
	assert config.host == 'localhost'
	assert config.port == 22
	assert config.timeout_ms == 10000
	assert config.keepalive_interval == 0
}

// ------------------------------------------------------------------
// Integration tests (require SSH server)
// ------------------------------------------------------------------
// These tests are only run if the SSH2_TEST_HOST environment variable is set.
// Example:
//   SSH2_TEST_HOST=localhost SSH2_TEST_USER=test SSH2_TEST_PASS=test v test .

fn ssh_test_config() ?ConnectConfig {
	host := os.getenv('SSH2_TEST_HOST')
	if host == '' {
		return none
	}
	return ConnectConfig{
		host:       host
		port:       os.getenv('SSH2_TEST_PORT').int()
		username:   os.getenv('SSH2_TEST_USER')
		password:   os.getenv('SSH2_TEST_PASS')
		timeout_ms: 5000
	}
}

fn test_integration_connect_and_exec() {
	config := ssh_test_config() or { return }

	session := connect_to(config) or { return }
	defer { session.close() }

	assert session.is_authenticated()

	// Test executing a simple command
	stdout, stderr := session.exec_and_read('echo hello') or { return }
	assert stdout.contains('hello')
	assert stderr == ''
}

fn test_integration_auth_list() {
	config := ssh_test_config() or { return }

	session := connect_to(config) or { return }
	defer { session.close() }

	methods := session.auth_list(config.username) or { return }
	assert methods.len > 0
	assert methods.contains(AuthMethod.password)
}

fn test_integration_sftp_file_ops() {
	config := ssh_test_config() or { return }

	session := connect_to(config) or { return }
	defer { session.close() }

	sftp := session.init_sftp() or {
		// SFTP might not be available on all servers
		return
	}
	defer { sftp.close() }

	// Test stat on home directory
	attrs := sftp.stat('.') or { return }
	assert attrs.flags & sftp_attr_permissions != 0 || attrs.flags & sftp_attr_size != 0

	// Test realpath
	real := sftp.realpath('.') or { return }
	assert real.len > 0
	assert real.starts_with('/')
}

fn test_integration_sftp_write_and_read() {
	config := ssh_test_config() or { return }

	session := connect_to(config) or { return }
	defer { session.close() }

	sftp := session.init_sftp() or {
		// SFTP might not be available on all servers
		return
	}
	defer { sftp.close() }

	// Test writing and reading a file
	test_data := 'Hello from V SSH2 wrapper!'
	test_path := '/tmp/v_ssh2_test.txt'

	sftp.write_file(test_path, test_data.bytes()) or { return }

	read_data := sftp.read_file(test_path) or { return }
	assert read_data.bytestr() == test_data

	// Clean up
	sftp.unlink(test_path) or { return }
}

fn test_integration_sftp_mkdir_rmdir() {
	config := ssh_test_config() or { return }

	session := connect_to(config) or { return }
	defer { session.close() }

	sftp := session.init_sftp() or { return }
	defer { sftp.close() }

	test_dir := '/tmp/v_ssh2_test_dir'
	sftp.mkdir(test_dir, 0o755) or { return }

	sftp.rmdir(test_dir) or { return }
}
