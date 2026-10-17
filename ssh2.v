// Copyright (c) 2024
// Licensed under MIT License.
// ssh2 - A V language wrapper for libssh2.
//
// This module provides a pure V interface to libssh2, allowing users
// to work with SSH connections, authentication, channels, and SFTP
// without writing any C code.
//
// ## Prerequisites
//
// libssh2 must be installed on your system. Run the setup task to auto-install:
//
// ```bash
// v run build.vsh setup
// ```
//
// Or install manually:
//
//   macOS:        brew install libssh2
//   Ubuntu/Deb:   sudo apt-get install libssh2-1-dev
//   Fedora:       sudo dnf install libssh2-devel
//   Arch:         sudo pacman -S libssh2
//   Alpine:       sudo apk add libssh2-dev
//

module ssh2

// #flag and #include directives for linking libssh2
// Uses pkg-config for portable library discovery across macOS, Linux, etc.
#pkgconfig libssh2
#include <libssh2.h>
#include <libssh2_sftp.h>

// ------------------------------------------------------------------
// Opaque C type forward declarations from libssh2
// These are defined by the libssh2 C headers. The empty `@[typedef]` struct
// bodies tell V's type checker these types exist without needing their internals.
// ------------------------------------------------------------------
@[typedef]
struct C.LIBSSH2_SESSION {}

@[typedef]
struct C.LIBSSH2_CHANNEL {}

@[typedef]
struct C.LIBSSH2_SFTP {}

@[typedef]
struct C.LIBSSH2_SFTP_HANDLE {}

@[typedef]
struct C.LIBSSH2_KNOWNHOSTS {}

@[typedef]
struct C.LIBSSH2_KNOWNHOST {}

// Library constants
// Version string for the wrapped libssh2
const libssh2_version_string = 'libssh2'

// Default buffer sizes
pub const default_read_buffer_size = 32768
pub const default_write_buffer_size = 4096

// ------------------------------------------------------------------
// C function declarations (referenced from libssh2)
// ------------------------------------------------------------------

// init_libssh2 initializes the libssh2 library. Must be called once before
// any other libssh2 functions. Returns 0 on success.
fn C.libssh2_init(flag int) int

// exit_libssh2 shuts down the libssh2 library. Call when done.
fn C.libssh2_exit()

// libssh2_version returns the version string of the libssh2 library.
fn C.libssh2_version(needed int) &char

// ------------------------------------------------------------------
// Error types
// ------------------------------------------------------------------

// Ssh2Error represents an error returned by the libssh2 library.
pub struct Ssh2Error {
	code int
pub:
	message string
}

pub fn (e Ssh2Error) str() string {
	return 'Ssh2Error(${e.code}): ${e.message}'
}

pub fn (e Ssh2Error) err() string {
	return e.str()
}

// msg implements the IError interface.
pub fn (e Ssh2Error) msg() string {
	return e.message
}

// code returns the numeric error code.
pub fn (e Ssh2Error) code() int {
	return e.code
}

// ------------------------------------------------------------------
// Automatic library initialization
// ------------------------------------------------------------------
// V's `init()` runs automatically when the module is imported — no user
// action needed. `deinit()` cleans up at program exit.

fn init() {
	rc := C.libssh2_init(0)
	if rc != 0 {
		panic('Failed to initialize libssh2 library (code: ${rc}). Is libssh2 installed? Run: v run build.vsh setup')
	}
}

fn deinit() {
	C.libssh2_exit()
}

// ------------------------------------------------------------------
// Helper functions
// ------------------------------------------------------------------

// version returns the version string of the underlying libssh2 library.
pub fn version() string {
	ptr := C.libssh2_version(0)
	return unsafe { cstring_to_vstring(ptr) }
}

// ------------------------------------------------------------------
// libssh2 error codes
// ------------------------------------------------------------------
// These mirror the `LIBSSH2_ERROR_*` constants declared in <libssh2.h>.
// Keeping them in sync matters: several code paths distinguish "no data yet"
// (`error_eagain`) from a real failure.
pub const error_socket_none = -1
pub const error_banner_recv = -2
pub const error_banner_send = -3
pub const error_invalid_mac = -4
pub const error_kex_failure = -5
pub const error_alloc = -6
pub const error_socket_send = -7
pub const error_key_exchange_failure = -8
pub const error_timeout = -9
pub const error_hostkey_init = -10
pub const error_hostkey_sign = -11
pub const error_decrypt = -12
pub const error_socket_disconnect = -13
pub const error_proto = -14
pub const error_password_expired = -15
pub const error_file = -16
pub const error_method_none = -17
pub const error_authentication_failed = -18
pub const error_publickey_unverified = -19
pub const error_channel_outoforder = -20
pub const error_channel_failure = -21
pub const error_channel_request_denied = -22
pub const error_channel_unknown = -23
pub const error_channel_window_exceeded = -24
pub const error_channel_packet_exceeded = -25
pub const error_channel_closed = -26
pub const error_channel_eof_sent = -27
pub const error_scp_protocol = -28
pub const error_zlib = -29
pub const error_socket_timeout = -30
pub const error_sftp_protocol = -31
pub const error_request_denied = -32
pub const error_method_not_supported = -33
pub const error_inval = -34
pub const error_invalid_poll_type = -35
pub const error_publickey_protocol = -36
pub const error_eagain = -37

// Session-level block directions, returned by `Session.block_directions()`.
// They mirror `LIBSSH2_SESSION_BLOCK_INBOUND` / `OUTBOUND`.
pub const session_block_inbound = 0x0001
pub const session_block_outbound = 0x0002

// is_error_code reports whether `rc` is a libssh2 error (negative) instead of a
// byte count.
pub fn is_error_code(rc int) bool {
	return rc < 0
}

// is_eagain reports whether `err` means "the operation would block".
// Non-blocking calls return this instead of blocking; it is not a real failure.
pub fn is_eagain(rc int) bool {
	return rc == error_eagain
}

// strerror maps a libssh2 error code to a human readable description.
pub fn strerror(code int) string {
	return socket_error_message(code)
}

fn socket_error_message(code int) string {
	return match code {
		error_socket_none { 'socket none' }
		error_banner_recv { 'banner receive failed' }
		error_banner_send { 'banner send failed' }
		error_invalid_mac { 'invalid MAC' }
		error_kex_failure { 'key exchange failure' }
		error_alloc { 'memory allocation failure' }
		error_socket_send { 'socket send error' }
		error_key_exchange_failure { 'key exchange failure' }
		error_timeout { 'timeout' }
		error_hostkey_init { 'host key init failed' }
		error_hostkey_sign { 'host key sign failed' }
		error_decrypt { 'decrypt failed' }
		error_socket_disconnect { 'socket disconnected' }
		error_proto { 'protocol error' }
		error_password_expired { 'password expired' }
		error_file { 'file error' }
		error_method_none { 'no authentication method available' }
		error_authentication_failed { 'authentication failed' }
		error_publickey_unverified { 'public key unverified' }
		error_channel_outoforder { 'channel out of order' }
		error_channel_failure { 'channel failure' }
		error_channel_request_denied { 'channel request denied' }
		error_channel_unknown { 'unknown channel' }
		error_channel_window_exceeded { 'channel window exceeded' }
		error_channel_packet_exceeded { 'channel packet exceeded' }
		error_channel_closed { 'channel closed' }
		error_channel_eof_sent { 'channel EOF already sent' }
		error_scp_protocol { 'SCP protocol error' }
		error_zlib { 'zlib error' }
		error_socket_timeout { 'socket timeout' }
		error_sftp_protocol { 'SFTP protocol error' }
		error_request_denied { 'request denied' }
		error_method_not_supported { 'method not supported' }
		error_inval { 'invalid parameter' }
		error_invalid_poll_type { 'invalid poll type' }
		error_publickey_protocol { 'public key protocol error' }
		error_eagain { 'would block (no data available)' }
		else { 'unknown error (${code})' }
	}
}
