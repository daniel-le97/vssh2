module ssh2

#include <libssh2.h>

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_knownhost_init(session &C.LIBSSH2_SESSION) &C.LIBSSH2_KNOWNHOSTS
fn C.libssh2_knownhost_free(knownhosts &C.LIBSSH2_KNOWNHOSTS)
fn C.libssh2_knownhost_readfile(knownhosts &C.LIBSSH2_KNOWNHOSTS, filename &char, typ int) int
fn C.libssh2_knownhost_writefile(knownhosts &C.LIBSSH2_KNOWNHOSTS, filename &char, typ int) int
fn C.libssh2_knownhost_readline(knownhosts &C.LIBSSH2_KNOWNHOSTS, line &char, line_len int, host &C.LIBSSH2_KNOWNHOST, typ int) int
fn C.libssh2_knownhost_writeline(knownhosts &C.LIBSSH2_KNOWNHOSTS, host &C.LIBSSH2_KNOWNHOST, buf voidptr, buflen int, outlen &int, typ int) int
fn C.libssh2_knownhost_addc(knownhosts &C.LIBSSH2_KNOWNHOSTS, host &char, salt &char, key &char, keylen int, typ int, store &&C.LIBSSH2_KNOWNHOST) int
fn C.libssh2_knownhost_checkp(knownhosts &C.LIBSSH2_KNOWNHOSTS, host &char, port int, key &char, keylen int, typ int, knownhost &&C.LIBSSH2_KNOWNHOST) int

// KnownHostCheckResult represents the result of a known host check.
pub enum KnownHostCheckResult {
	match
	mismatch
	not_found
	failure
}

// KnownHosts manages known hosts for SSH server verification.
pub struct KnownHosts {
	handle  voidptr = unsafe { nil }
	session &Session
}

// new_knownhosts creates a new known hosts store for the given session.
pub fn (s &Session) new_knownhosts() !&KnownHosts {
	handle := C.libssh2_knownhost_init(s.handle)
	if unsafe { handle == nil } {
		return error('Failed to initialize known hosts store')
	}
	return &KnownHosts{
		handle:  handle
		session: s
	}
}

// close frees the known hosts store.
pub fn (kh &KnownHosts) close() {
	if unsafe { kh.handle != nil } {
		C.libssh2_knownhost_free(kh.handle)
	}
}

// read_file reads known hosts from a file.
// The type parameter indicates the file format:
//   0 = OpenSSH-style known_hosts file
//   1 = RFC 4716-style known_hosts file
pub fn (kh &KnownHosts) read_file(filename string, typ int) ! {
	rc := C.libssh2_knownhost_readfile(kh.handle, &char(filename.str), typ)
	if rc < 0 {
		return ssh2_error(rc, kh.session)
	}
}

// write_file writes known hosts to a file.
pub fn (kh &KnownHosts) write_file(filename string, typ int) ! {
	rc := C.libssh2_knownhost_writefile(kh.handle, &char(filename.str), typ)
	if rc < 0 {
		return ssh2_error(rc, kh.session)
	}
}

// add_host adds a host to the known hosts store.
pub fn (kh &KnownHosts) add_host(host string, key []u8, typ int) ! {
	ckey := &char(key.data)
	rc := C.libssh2_knownhost_addc(kh.handle, &char(host.str), &char(unsafe { nil }), ckey,
		key.len, typ, &&C.LIBSSH2_KNOWNHOST(unsafe { nil }))
	if rc != 0 {
		return ssh2_error(rc, kh.session)
	}
}

// check_host checks whether the given host+key matches the known hosts store.
// Returns KnownHostCheckResult.match if found and matching,
// KnownHostCheckResult.mismatch if found but different,
// KnownHostCheckResult.not_found if not in the store.
pub fn (kh &KnownHosts) check_host(host string, port int, key []u8, key_type int) !KnownHostCheckResult {
	ckey := &char(key.data)
	mut known := &C.LIBSSH2_KNOWNHOST(unsafe { nil })

	rc := C.libssh2_knownhost_checkp(kh.handle, &char(host.str), port, ckey, key.len, key_type,
		&known)

	return match rc {
		0 { KnownHostCheckResult.match }
		1 { KnownHostCheckResult.mismatch }
		2 { KnownHostCheckResult.not_found }
		else { KnownHostCheckResult.failure }
	}
}

// knownhost file format constants
pub const knownhost_file_format_openssh = 0
pub const knownhost_file_format_rfc4716 = 1

// KnownHost key types
pub const knownhost_type_plain = 0
pub const knownhost_type_sha1 = 1 // HMAC-SHA1 hashed hostname

pub const knownhost_type_custom = 2 // Custom type

pub const knownhost_type_rsa1 = 3 // SSH1 RSA key (deprecated)

pub const knownhost_type_rsa = 4 // SSH2 RSA key

pub const knownhost_type_dss = 5 // SSH2 DSS key

pub const knownhost_type_ecdsa_256 = 6
pub const knownhost_type_ecdsa_384 = 7
pub const knownhost_type_ecdsa_521 = 8
pub const knownhost_type_ed25519 = 9
