module vssh2

import os
import time

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
	// These must match the LIBSSH2_ERROR_* constants in <libssh2.h>.
	assert socket_error_message(error_socket_none) == 'socket none'
	assert socket_error_message(error_timeout) == 'timeout'
	assert socket_error_message(error_socket_disconnect) == 'socket disconnected'
	assert socket_error_message(error_file) == 'file error'
	assert socket_error_message(error_authentication_failed) == 'authentication failed'
	assert socket_error_message(error_eagain) == 'would block (no data available)'
	assert socket_error_message(999) == 'unknown error (999)'
}

fn test_error_helpers() {
	assert is_eagain(error_eagain)
	assert !is_eagain(error_timeout)
	assert is_error_code(-1)
	assert !is_error_code(0)
	assert strerror(error_eagain) == 'would block (no data available)'
	// The codes must line up with the values declared in libssh2.h.
	assert error_eagain == -37
	assert error_timeout == -9
	assert error_authentication_failed == -18
	assert error_sftp_protocol == -31
}

fn test_session_blocking_mode() {
	mut session := new_session() or { return }
	defer {
		session.close()
	}

	// Default is blocking
	assert session.is_blocking()

	// Switch to non-blocking
	session.set_blocking(false)
	assert !session.is_blocking()

	// Switch back
	session.set_blocking(true)
	assert session.is_blocking()
}

fn test_session_close_is_idempotent() {
	mut session := new_session() or { return }
	assert !session.is_closed()
	session.close()
	assert session.is_closed()
	// Must not crash or double-free.
	session.close()
	assert session.is_closed()
}

fn test_session_timeout() {
	mut session := new_session() or { return }
	defer {
		session.close()
	}

	session.set_timeout(5000)
	assert session.timeout() == 5000
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
	assert methods3.len == 0

	// Trailing/duplicate separators must not produce `unknown` entries.
	methods4 := parse_auth_methods('password,')
	assert methods4.len == 1
	assert methods4[0] == AuthMethod.password
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
	// These must match LIBSSH2_FXF_* in <libssh2_sftp.h>. They were previously
	// shifted by one bit, which made write_file() open with WRITE|TRUNC|EXCL
	// (no CREAT) and fail on every call.
	assert sftp_open_flag_read == 0x01
	assert sftp_open_flag_write == 0x02
	assert sftp_open_flag_append == 0x04
	assert sftp_open_flag_create == 0x08
	assert sftp_open_flag_trunc == 0x10
	assert sftp_open_flag_excl == 0x20

	read_write := sftp_open_flag_read | sftp_open_flag_write
	assert read_write == 0x03

	// The combination used by write_file(): create + truncate an existing file.
	create_trunc := sftp_open_flag_write | sftp_open_flag_create | sftp_open_flag_trunc
	assert create_trunc == 0x1a
	assert create_trunc & sftp_open_flag_create != 0
}

fn test_sftp_strerror() {
	assert sftp_strerror(sftp_fx_ok) == 'success'
	assert sftp_strerror(sftp_fx_no_such_file) == 'no such file'
	assert sftp_strerror(sftp_fx_permission_denied) == 'permission denied'
	assert sftp_strerror(sftp_fx_dir_not_empty) == 'directory not empty'
	assert sftp_strerror(u64(999)) == 'SFTP error 999'
	// SFTP status codes are a different namespace from LIBSSH2_ERROR_*.
	assert sftp_fx_no_such_file == 2
	assert error_eagain == -37
}

fn test_dial_address_formats() {
	assert dial_address('example.com', 22) == 'example.com:22'
	assert dial_address('127.0.0.1', 2222) == '127.0.0.1:2222'
	// Bare IPv6 literals must be bracketed or the port is misparsed.
	assert dial_address('::1', 22) == '[::1]:22'
	assert dial_address('[::1]', 22) == '[::1]:22'
}

fn test_known_hosts_tilde_expansion() {
	config := ConnectConfig{
		host_key_mode:    .accept_new
		known_hosts_file: '~/.ssh/known_hosts'
	}
	path := config.known_hosts_path()
	assert !path.starts_with('~')
	assert path.ends_with('known_hosts')

	// Explicit paths are left alone (except for `~`).
	explicit := ConnectConfig{
		known_hosts_file: '/etc/ssh/ssh_known_hosts'
	}
	assert explicit.known_hosts_path() == '/etc/ssh/ssh_known_hosts'
}

fn test_closed_session_is_safe() {
	mut session := new_session() or { return }
	session.close()
	assert session.is_closed()
	// Every accessor must tolerate a freed handle instead of calling into C.
	assert !session.is_authenticated()
	assert !session.is_blocking()
	assert session.last_errno() == error_socket_none
	code, _ := session.last_error()
	assert code == error_socket_none
	assert session.banner() == ''
	assert session.method(.kex) == ''
	key, key_len, key_type := session.hostkey()
	assert key.len == 0 && key_len == 0 && key_type == 0
	assert session.block_directions() == 0
	if _ := session.send_keepalive() {
		assert false, 'send_keepalive on a closed session must fail'
	}
	if _ := session.open_channel() {
		assert false, 'open_channel on a closed session must fail'
	}
	if _ := session.init_sftp() {
		assert false, 'init_sftp on a closed session must fail'
	}
	if _ := session.auth_password('u', 'p') {
		assert false, 'auth on a closed session must fail'
	}
}

// ------------------------------------------------------------------
// Compile-only API sweep
// ------------------------------------------------------------------
// V dead-code-eliminates unreachable functions in an executable, so `v test .`
// used to skip C codegen for most of the public API. That hid real ABI bugs
// (wrong macro arity for setenv/setstat, wrong keyboard-interactive struct
// names, macro-vs-function mismatches) until a user called the function.
// Referencing every entry point from a test forces the full module through the
// C compiler on every test run.
fn test_public_api_surface_compiles() {
	if os.getenv('SSH2_API_SWEEP') == '' {
		return
	}
	api_sweep()
}

fn api_sweep() {
	mut s := &Session{}
	s.set_blocking(true)
	_ = s.is_blocking()
	s.set_timeout(1000)
	_ = s.timeout()
	s.configure_keepalive(true, 30)
	_ = s.send_keepalive() or { 0 }
	_ = s.block_directions()
	_ = s.banner()
	s.set_banner('sweep') or {}
	_ = s.method(.kex)
	_, _, _ := s.hostkey()
	_ = s.last_errno()
	_, _ := s.last_error()
	_ = s.is_closed()
	_ = s.is_authenticated()
	s.auth_password('u', 'p') or {}
	s.auth_publickey_fromfile('u', '', 'k', '') or {}
	s.auth_publickey_frommemory('u', []u8{}, []u8{len: 1}, '') or {}
	s.auth_hostbased_fromfile('u', 'h', 'u', 'pub', 'priv', '') or {}
	s.auth_keyboard_interactive('u', fn (questions []string, _ []bool) []string {
		return []string{len: questions.len, init: ''}
	}) or {}
	_ = s.auth_list('u') or { []AuthMethod{} }

	if sftp := s.init_sftp() {
		_ = sftp.exists('/x')
		_ = sftp.stat('/x') or { SftpAttrs{} }
		_ = sftp.lstat('/x') or { SftpAttrs{} }
		sftp.chmod('/x', 0o644) or {}
		sftp.setstat('/x', &SftpAttrs{}) or {}
		sftp.mkdir('/x', 0o755) or {}
		sftp.rmdir('/x') or {}
		sftp.unlink('/x') or {}
		sftp.rename('/x', '/y') or {}
		_ = sftp.realpath('/x') or { '' }
		_ = sftp.readlink('/x') or { '' }
		_ = sftp.list_dir('/x') or { []SftpFile{} }
		_ = sftp.read_file('/x') or { []u8{} }
		sftp.write_file('/x', 'd'.bytes()) or {}
		if fh := sftp.open('/x', sftp_open_flag_read, 0o644) {
			_ = fh.read([]u8{len: 8}) or { 0 }
			_ = fh.write([]u8{len: 8}) or { 0 }
			_ = fh.stat() or { SftpAttrs{} }
			fh.close()
		}
		sftp.close()
	}

	if mut kh := s.new_knownhosts() {
		kh.read_file('/x', knownhost_file_format_openssh) or {}
		kh.write_file('/x', knownhost_file_format_openssh) or {}
		kh.add_host('h', []u8{}, 0) or {}
		_ = kh.check_host('h', 22, []u8{}, 0) or { KnownHostCheckResult.failure }
		kh.close()
	}

	_ = s.verify_host_key('h', 22, '/x', false) or { KnownHostCheckResult.failure }

	if mut ch := s.open_channel() {
		ch.exec('true') or {}
		ch.setenv('A', 'B') or {}
		ch.request_pty('xterm') or {}
		ch.request_pty_size('xterm', 80, 24) or {}
		ch.shell() or {}
		ch.subsystem('sftp') or {}
		_ = ch.read([]u8{len: 8}) or { 0 }
		_ = ch.read_stderr([]u8{len: 8}) or { 0 }
		_ = ch.write([]u8{len: 8}) or { 0 }
		_ = ch.write_string('x') or { 0 }
		ch.write_all([]u8{len: 8}) or {}
		ch.write_string_all('x') or {}
		ch.send_eof() or {}
		_ = ch.eof()
		ch.wait_eof() or {}
		ch.wait_closed() or {}
		_ = ch.exit_status()
		ch.flush() or {}
		ch.flush_stderr() or {}
		_ = ch.pump() or { PumpResult{} }
		ch.close()
	}

	if mut proc := s.start('true') {
		_ = proc.pump() or { PumpResult{} }
		_ = proc.finish() or { -1 }
		_ = proc.exit_code()
		proc.kill()
	}

	_, _ = s.exec_and_read('true') or { '', '' }
	_ = s.run('true') or { ExecResult{} }
	_ = s.run_timeout('true', 100) or { ExecResult{} }
	_ = s.run_stream('true', fn (_ string) {}) or { ExecResult{} }
	_ = s.run_stream_timeout('true', fn (_ string) {}, 100) or { ExecResult{} }
	_ = s.run_stream_split('true', fn (_ string) {}, fn (_ string) {}) or { ExecResult{} }
	mut sink := DiscardSink{}
	_ = s.run_sink('true', mut sink) or { ExecResult{} }
	_ = s.run_sink_timeout('true', mut sink, 100) or { ExecResult{} }

	s.disconnect('bye') or {}
	s.close()
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

fn test_knownhost_key_flag() {
	// Values follow LIBSSH2_HOSTKEY_TYPE_*.
	assert knownhost_key_flag(1) == knownhost_key_sshrsa
	assert knownhost_key_flag(2) == knownhost_key_sshdss
	assert knownhost_key_flag(3) == knownhost_key_ecdsa_256
	assert knownhost_key_flag(6) == knownhost_key_ed25519
	assert knownhost_key_flag(0) == knownhost_key_unknown
	assert knownhost_key_flag(99) == knownhost_key_unknown
	// These are the LIBSSH2_KNOWNHOST_* values from libssh2.h.
	assert knownhost_type_plain == 1
	assert knownhost_keyenc_raw == 1 << 16
	assert knownhost_key_ed25519 == 7 << 18
	assert knownhost_file_format_openssh == 1
}

fn test_sftp_attrs_file_type() {
	assert SftpAttrs{ permissions: 0o100644 }.file_type() == .regular
	assert SftpAttrs{ permissions: 0o040755 }.file_type() == .directory
	assert SftpAttrs{ permissions: 0o120777 }.file_type() == .symlink
	assert SftpAttrs{ permissions: 0o010644 }.file_type() == .special
	assert SftpAttrs{}.file_type() == .unknown
	assert SftpAttrs{ permissions: 0o040755 }.is_dir()
	assert !SftpAttrs{ permissions: 0o100644 }.is_dir()
	assert SftpAttrs{ permissions: 0o040755 }.mode() == 0o755
}

fn test_exec_result_helpers() {
	both := ExecResult{
		exit_code: 0
		stdout:    'out'
		stderr:    'err'
	}
	assert both.output() == 'outerr'
	assert both.ok()
	assert ExecResult{
		exit_code: 1
		stdout:    'x'
	}.output() == 'x'
	assert ExecResult{
		exit_code: 1
		stderr:    'y'
	}.output() == 'y'
	assert !ExecResult{
		exit_code: 2
		stdout:    'y'
	}.ok()
}

fn test_connect_config_host_key_defaults() {
	// Verification stays opt-in so existing callers keep working unchanged.
	config := ConnectConfig{}
	assert config.host_key_mode == .ignore
	assert config.known_hosts_path().ends_with('known_hosts')
}

// ------------------------------------------------------------------
// Integration tests (require SSH server)
// ------------------------------------------------------------------
// These tests are only run if the SSH2_TEST_HOST environment variable is set.
// Example:
//   SSH2_TEST_HOST=localhost SSH2_TEST_USER=test SSH2_TEST_PASS=test v test .

// env_test_port returns SSH2_TEST_PORT, defaulting to 22. A struct literal sets
// the field to 0 when the env var is missing, which would dial port 0.
fn env_test_port() int {
	port := os.getenv('SSH2_TEST_PORT').int()
	return if port > 0 { port } else { 22 }
}

fn ssh_test_config() ?ConnectConfig {
	host := os.getenv('SSH2_TEST_HOST')
	if host == '' {
		return none
	}
	return ConnectConfig{
		host:       host
		port:       env_test_port()
		username:   os.getenv('SSH2_TEST_USER')
		password:   os.getenv('SSH2_TEST_PASS')
		timeout_ms: 5000
	}
}

fn test_integration_connect_and_exec() {
	config := ssh_test_config() or { return }

	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	assert session.is_authenticated()

	// Test executing a simple command
	stdout, stderr := session.exec_and_read('echo hello') or { return }
	assert stdout.contains('hello')
	assert stderr == ''
}

fn test_integration_auth_list() {
	config := ssh_test_config() or { return }

	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	methods := session.auth_list(config.username) or { return }
	assert methods.len > 0
	assert methods.contains(AuthMethod.password)
}

fn test_integration_sftp_file_ops() {
	config := ssh_test_config() or { return }

	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	mut sftp := session.init_sftp() or {
		// SFTP might not be available on all servers
		return
	}
	defer {
		sftp.close()
	}

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

	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	mut sftp := session.init_sftp() or {
		// SFTP might not be available on all servers
		return
	}
	defer {
		sftp.close()
	}

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

	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	mut sftp := session.init_sftp() or { return }
	defer {
		sftp.close()
	}

	test_dir := '/tmp/v_ssh2_test_dir'
	sftp.mkdir(test_dir, 0o755) or { return }

	sftp.rmdir(test_dir) or { return }
}

// ------------------------------------------------------------------
// Integration tests driven by a private key (no password, no .pub file)
// ------------------------------------------------------------------
// Set SSH2_TEST_KEY (and optionally SSH2_TEST_HOST/SSH2_TEST_PORT/
// SSH2_TEST_USER) to exercise these. The public key file is deliberately NOT
// derived from the private key path: key auth used to fail with
// "Unable to open public key file" in that case.

fn ssh_test_key_config() ?ConnectConfig {
	key := os.getenv('SSH2_TEST_KEY')
	if key == '' {
		return none
	}
	return ConnectConfig{
		host:         os.getenv('SSH2_TEST_HOST')
		port:         env_test_port()
		username:     os.getenv('SSH2_TEST_USER')
		privkey_file: key
		timeout_ms:   8000
	}
}

fn test_integration_key_auth_without_public_key_file() {
	config := ssh_test_key_config() or { return }

	mut session := connect_to(config) or {
		assert false, 'key auth without a .pub file must work: ${err}'
		return
	}
	defer {
		session.close()
	}

	assert session.is_authenticated()
	res := session.run('echo key-auth-ok') or { return }
	assert res.stdout.trim_space() == 'key-auth-ok'
}

fn test_integration_run_and_exit_status() {
	config := ssh_test_key_config() or { return }
	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	ok := session.run('true') or { return }
	assert ok.exit_code == 0
	assert ok.ok()

	failed := session.run('exit 7') or { return }
	assert failed.exit_code == 7
	assert !failed.ok()

	// stderr and stdout must both be captured.
	mixed := session.run('echo to-stdout; echo to-stderr 1>&2') or { return }
	assert mixed.stdout.trim_space() == 'to-stdout'
	assert mixed.stderr.trim_space() == 'to-stderr'
	assert mixed.output().contains('to-stdout')
	assert mixed.output().contains('to-stderr')
}

// A sink that records when the first chunk arrived — proves output is delivered
// live rather than buffered until the command finishes.
struct TimingSink {
mut:
	start         time.Time
	first_seen_ms i64 = -1
}

fn (mut s TimingSink) write(chunk string) {
	if s.first_seen_ms < 0 && chunk.contains('FIRST') {
		s.first_seen_ms = time.since(s.start).milliseconds()
	}
}

// A sink that counts chunks — proves output is streamed in pieces.
struct CountingSink {
mut:
	chunks int
	total  int
}

fn (mut c CountingSink) write(chunk string) {
	c.chunks++
	c.total += chunk.len
}

fn test_integration_streaming_is_live() {
	config := ssh_test_key_config() or { return }
	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	// The command emits a marker, stays quiet for two seconds, then emits more.
	// The first marker must reach the sink well before the command ends —
	// otherwise output is being buffered until completion.
	mut sink := &TimingSink{
		start: time.now()
	}
	res := session.run_sink('echo FIRST 1>&2; sleep 2; echo SECOND 1>&2', mut sink) or {
		assert false, 'streaming failed: ${err}'
		return
	}
	total_ms := time.since(sink.start).milliseconds()

	assert res.stderr.contains('FIRST')
	assert res.stderr.contains('SECOND')
	assert sink.first_seen_ms >= 0, 'the sink was never written to'
	assert sink.first_seen_ms < 1500, 'FIRST arrived after ${sink.first_seen_ms}ms (buffered, not streamed)'
	assert total_ms >= 2000
}

fn test_integration_stream_large_stderr_does_not_deadlock() {
	config := ssh_test_key_config() or { return }
	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	// 8 MB on stderr while stdout stays idle for most of the run. Reading stdout
	// to EOF before touching stderr used to deadlock once the ~2 MB channel
	// window filled up — which is what `docker build` log streaming hits.
	mut sink := &CountingSink{}
	res := session.run_sink("head -c 8000000 /dev/zero | tr '\\0' 'x' 1>&2; echo STDOUT-DONE", mut sink) or {
		assert false, '8MB of stderr must not deadlock the connection: ${err}'
		return
	}

	assert res.stderr.len == 8000000
	assert res.stdout.contains('STDOUT-DONE')
	assert sink.chunks > 1, 'output arrived in a single chunk instead of streaming'
	assert sink.total >= 8000000
}

fn test_integration_both_streams_busy() {
	config := ssh_test_key_config() or { return }
	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	// Both streams produce 3 MB at the same time. Any reader that drains one
	// stream to EOF before the other stalls here.
	cmd := "(head -c 3000000 /dev/zero | tr '\\0' 'a') & (head -c 3000000 /dev/zero | tr '\\0' 'b' 1>&2) & wait"
	res := session.run(cmd) or {
		assert false, 'concurrent stdout+stderr must not deadlock: ${err}'
		return
	}
	assert res.stdout.len == 3000000
	assert res.stderr.len == 3000000
}

fn test_integration_exec_process_pump() {
	config := ssh_test_key_config() or { return }
	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}

	// The caller drives the loop and owns all the state.
	mut proc := session.start('echo one; sleep 0.3; echo two; exit 3') or {
		assert false, 'start failed: ${err}'
		return
	}
	mut collected := ''
	for {
		out := proc.pump() or { break }
		collected += out.stdout
		if out.eof {
			break
		}
		time.sleep(10 * time.millisecond)
	}
	code := proc.finish() or {
		assert false, 'finish failed: ${err}'
		return
	}
	assert code == 3
	assert proc.exit_code() == 3
	assert collected.contains('one')
	assert collected.contains('two')
}

fn fd_count() int {
	entries := os.ls('/proc/self/fd') or { return -1 }
	return entries.len
}

fn test_integration_close_does_not_leak_fds() {
	config := ssh_test_key_config() or { return }
	// /proc is Linux-only; skip elsewhere.
	before := fd_count()
	if before < 0 {
		return
	}

	for _ in 0 .. 10 {
		mut session := connect_to(config) or { return }
		res := session.run('true') or { return }
		assert res.ok()
		session.close()
	}

	after := fd_count()
	assert after <= before + 2, 'file descriptors leaked across 10 sessions: ${before} -> ${after}'
}

fn test_integration_sftp_list_dir_and_exists() {
	config := ssh_test_key_config() or { return }
	mut session := connect_to(config) or { return }
	defer {
		session.close()
	}
	mut sftp := session.init_sftp() or { return }
	defer {
		sftp.close()
	}

	assert sftp.exists('.')
	assert !sftp.exists('/definitely/not/here/vssh2')

	dir := '/tmp/v_ssh2_listdir_test'
	sftp.mkdir(dir, 0o755) or { return }
	defer {
		sftp.rmdir(dir) or {}
	}
	sftp.write_file('${dir}/a.txt', 'a'.bytes()) or { return }

	files := sftp.list_dir(dir) or { return }
	assert files.len == 1
	assert files[0].name == 'a.txt'
	assert files[0].attrs.size == 1
	assert !files[0].is_dir()

	st := sftp.stat(dir) or { return }
	assert st.is_dir()
	assert st.file_type() == .directory

	sftp.unlink('${dir}/a.txt') or { return }
}

fn test_integration_host_key_verification() {
	base := ssh_test_key_config() or { return }
	tmp_dir := os.temp_dir()
	known_hosts := os.join_path(tmp_dir, 'vssh2_known_hosts_test')
	empty_hosts := os.join_path(tmp_dir, 'vssh2_known_hosts_empty')
	os.rm(known_hosts) or {}
	os.rm(empty_hosts) or {}
	defer {
		os.rm(known_hosts) or {}
		os.rm(empty_hosts) or {}
	}

	// accept_new records the key on first use and matches it afterwards.
	accept_new := ConnectConfig{
		...base
		host_key_mode:    .accept_new
		known_hosts_file: known_hosts
	}
	mut first := connect_to(accept_new) or {
		assert false, 'accept_new must accept an unknown host: ${err}'
		return
	}
	first.close()
	assert os.exists(known_hosts)
	assert os.read_file(known_hosts) or { '' }.len > 0

	mut second := connect_to(accept_new) or {
		assert false, 'accept_new must match the recorded key: ${err}'
		return
	}
	second.close()

	// strict succeeds against the recorded key...
	strict_known := ConnectConfig{
		...base
		host_key_mode:    .strict
		known_hosts_file: known_hosts
	}
	mut third := connect_to(strict_known) or {
		assert false, 'strict must accept the recorded key: ${err}'
		return
	}
	third.close()

	// ...and refuses an unknown host.
	strict_unknown := ConnectConfig{
		...base
		host_key_mode:    .strict
		known_hosts_file: empty_hosts
	}
	if _ := connect_to(strict_unknown) {
		assert false, 'strict mode must reject an unknown host key'
	}

	// A known host presenting a different key must be rejected as well. The
	// client's own public key is a valid ed25519 blob that is definitely not the
	// server's host key.
	client_pub := os.read_file('${base.privkey_file}.pub') or { return }
	wrong_hosts := os.join_path(tmp_dir, 'vssh2_known_hosts_wrong')
	// OpenSSH omits the port for 22 and brackets `[host]:port` otherwise; use
	// the same format so the store actually matches the host and reports a
	// MISMATCH instead of NOT_FOUND.
	host_field := if base.port == 22 {
		base.host
	} else {
		'[${base.host}]:${base.port}'
	}
	os.write_file(wrong_hosts, '${host_field} ${client_pub.trim_space()}\n') or { return }
	defer {
		os.rm(wrong_hosts) or {}
	}
	strict_wrong := ConnectConfig{
		...base
		host_key_mode:    .strict
		known_hosts_file: wrong_hosts
	}
	if _ := connect_to(strict_wrong) {
		assert false, 'strict mode must reject a changed host key'
	}
}
