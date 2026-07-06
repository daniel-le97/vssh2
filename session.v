module ssh2

#include <libssh2.h>

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_session_init() &C.LIBSSH2_SESSION
fn C.libssh2_session_free(session &C.LIBSSH2_SESSION) int
fn C.libssh2_session_handshake(session &C.LIBSSH2_SESSION, sock int) int
fn C.libssh2_session_last_errno(session &C.LIBSSH2_SESSION) int
fn C.libssh2_session_last_error(session &C.LIBSSH2_SESSION, errmsg &&char, errmsg_len &int, want_buf int) int
fn C.libssh2_session_set_blocking(session &C.LIBSSH2_SESSION, blocking int)
fn C.libssh2_session_get_blocking(session &C.LIBSSH2_SESSION) int
fn C.libssh2_session_banner_get(session &C.LIBSSH2_SESSION) &char
fn C.libssh2_session_banner_set(session &C.LIBSSH2_SESSION, banner &char) int
fn C.libssh2_session_methods(session &C.LIBSSH2_SESSION, method_type int) &char
fn C.libssh2_session_hostkey(session &C.LIBSSH2_SESSION, len &int, typ &int) &char
fn C.libssh2_session_disconnect(session &C.LIBSSH2_SESSION, reason &char) int
fn C.libssh2_session_get_timeout(session &C.LIBSSH2_SESSION) int
fn C.libssh2_session_set_timeout(session &C.LIBSSH2_SESSION, timeout int)
fn C.libssh2_keepalive_config(session &C.LIBSSH2_SESSION, want_reply int, interval int)
fn C.libssh2_keepalive_send(session &C.LIBSSH2_SESSION, seconds_to_next &int) int

// MethodType represents a type of negotiated SSH algorithm.
// Used with `Session.method()` to query which algorithm was negotiated.
pub enum MethodType {
	kex
	hostkey
	crypt_cs
	crypt_sc
	mac_cs
	mac_sc
	comp_cs
	comp_sc
	lang_cs
	lang_sc
}

// Session represents an SSH2 session.
// It wraps a C LIBSSH2_SESSION pointer and handles its lifecycle.
@[heap]
pub struct Session {
mut:
	handle voidptr = unsafe { nil }
	// socket_fd is the underlying socket descriptor
	socket_fd int = -1
}

// ------------------------------------------------------------------
// Session lifecycle
// ------------------------------------------------------------------

// new_session creates a new SSH2 session without connecting.
// Call connect() to establish the connection.
pub fn new_session() !&Session {
	handle := C.libssh2_session_init()
	if isnil(handle) {
		return error('Failed to initialize SSH2 session')
	}
	return &Session{
		handle:    handle
		socket_fd: -1
	}
}

// connect performs the SSH handshake over the given socket.
// The socket should already be connected to the remote host.
// Returns an error if the handshake fails.
pub fn (mut s Session) connect(sock_fd int) ! {
	s.socket_fd = sock_fd
	rc := C.libssh2_session_handshake(s.handle, sock_fd)
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// disconnect sends a disconnect message to the remote host.
pub fn (s &Session) disconnect(message string) ! {
	rc := C.libssh2_session_disconnect(s.handle, &char(message.str))
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// close frees the session handle. Call this when done.
pub fn (s &Session) close() {
	if unsafe { s.handle != nil } {
		C.libssh2_session_free(s.handle)
	}
}

// ------------------------------------------------------------------
// Session configuration
// ------------------------------------------------------------------

// set_blocking sets whether the session operates in blocking mode.
pub fn (s &Session) set_blocking(blocking bool) {
	val := if blocking { 1 } else { 0 }
	C.libssh2_session_set_blocking(s.handle, val)
}

// is_blocking returns whether the session is in blocking mode.
pub fn (s &Session) is_blocking() bool {
	return C.libssh2_session_get_blocking(s.handle) != 0
}

// set_timeout sets the timeout (in milliseconds) for blocking calls.
pub fn (s &Session) set_timeout(timeout_ms int) {
	C.libssh2_session_set_timeout(s.handle, timeout_ms)
}

// timeout returns the current timeout in milliseconds.
pub fn (s &Session) timeout() int {
	return C.libssh2_session_get_timeout(s.handle)
}

// configure_keepalive configures keepalive messages.
//   want_reply: whether to request a reply from the server
//   interval:   interval in seconds between keepalive probes
pub fn (s &Session) configure_keepalive(want_reply bool, interval int) {
	wr := if want_reply { 1 } else { 0 }
	C.libssh2_keepalive_config(s.handle, wr, interval)
}

// send_keepalive sends a keepalive message if needed.
// Returns the number of seconds until the next keepalive is needed.
pub fn (s &Session) send_keepalive() !int {
	mut seconds_to_next := 0
	rc := C.libssh2_keepalive_send(s.handle, &seconds_to_next)
	if rc != 0 {
		return ssh2_error(rc, s)
	}
	return seconds_to_next
}

// ------------------------------------------------------------------
// Session information
// ------------------------------------------------------------------

// banner returns the banner text sent by the remote host.
pub fn (s &Session) banner() string {
	ptr := C.libssh2_session_banner_get(s.handle)
	if unsafe { ptr == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(ptr) }
}

// set_banner sets the local banner to send to the remote host.
pub fn (s &Session) set_banner(banner_text string) ! {
	rc := C.libssh2_session_banner_set(s.handle, &char(banner_text.str))
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// method returns the negotiated algorithm name for the given method type.
pub fn (s &Session) method(method_type MethodType) string {
	ptr := C.libssh2_session_methods(s.handle, int(method_type))
	if unsafe { ptr == nil } {
		return ''
	}
	return unsafe { cstring_to_vstring(ptr) }
}

// hostkey returns the remote host's hostkey.
// Returns (key_data, length, type).
pub fn (s &Session) hostkey() ([]u8, int, int) {
	mut key_len := 0
	mut key_type := 0
	ptr := C.libssh2_session_hostkey(s.handle, &key_len, &key_type)
	if unsafe { ptr == nil } {
		return []u8{}, 0, 0
	}
	// Copy the key data into a V byte slice
	mut result := []u8{len: key_len}
	unsafe {
		C.memcpy(result.data, ptr, key_len)
	}
	return result, key_len, key_type
}

// last_error returns the last error code and message for this session.
pub fn (s &Session) last_error() (int, string) {
	mut cmsg := &char(unsafe { nil })
	mut msg_len := 0
	code := C.libssh2_session_last_error(s.handle, &cmsg, &msg_len, 0)
	msg := unsafe { cstring_to_vstring(cmsg) }
	return code, msg
}

// ------------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------------

// ssh2_error creates an IError from a libssh2 error code.
fn ssh2_error(code int, s &Session) IError {
	msg := if unsafe { s != nil && s.handle != nil } {
		mut cmsg := &char(unsafe { nil })
		mut msg_len := 0
		C.libssh2_session_last_error(s.handle, &cmsg, &msg_len, 0)
		unsafe { cstring_to_vstring(cmsg) }
	} else {
		socket_error_message(code)
	}
	return Ssh2Error{
		code:    code
		message: msg
	}
}
