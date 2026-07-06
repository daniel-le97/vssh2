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
// libssh2 must be installed on your system. Run the setup script to auto-install:
//
// ```bash
// v run setup.vsh
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
// ## Why not bundled?
//
// libssh2 is LGPL-licensed (your project is MIT), and it depends on OpenSSL for
// crypto. Bundling it would create license obligations and still require users
// to install OpenSSL. Instead, we use your system's package manager — one command
// and you're set. See `setup.sh` for auto-detection.

module ssh2

// #flag and #include directives for linking libssh2
// Uses pkg-config for portable library discovery across macOS, Linux, etc.
#pkgconfig libssh2
#include <libssh2.h>

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
		panic('Failed to initialize libssh2 library (code: ${rc}). Is libssh2 installed? Run: v run setup.vsh')
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

// quoted key type strings
fn socket_error_message(code int) string {
	return match code {
		-1 { 'socket error' }
		-2 { 'socket send error' }
		-3 { 'socket timeout' }
		-4 { 'channel eof' }
		-5 { 'channel closed' }
		-6 { 'channel window exceeded' }
		-7 { 'channel out of order' }
		-8 { 'invalid parameter' }
		-9 { 'socket disconnected' }
		-10 { 'alloc error' }
		-11 { 'socket none' }
		-12 { 'invalid mac' }
		-13 { 'auth failed' }
		-14 { 'public key unverified' }
		-15 { 'channel failure' }
		-16 { 'sftp failure' }
		-17 { 'sftp bad message' }
		-18 { 'sftp permission denied' }
		-19 { 'sftp no such file' }
		-20 { 'sftp unsupported' }
		-21 { 'sftp no connection' }
		-22 { 'knownhosts failure' }
		-23 { 'channel unknown' }
		-24 { 'agent failure' }
		else { 'unknown error (${code})' }
	}
}
