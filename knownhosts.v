module vssh2

import os

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_knownhost_init(session &C.LIBSSH2_SESSION) &C.LIBSSH2_KNOWNHOSTS
fn C.libssh2_knownhost_free(knownhosts &C.LIBSSH2_KNOWNHOSTS)
fn C.libssh2_knownhost_readfile(knownhosts &C.LIBSSH2_KNOWNHOSTS, filename &char, typ int) int
fn C.libssh2_knownhost_writefile(knownhosts &C.LIBSSH2_KNOWNHOSTS, filename &char, typ int) int
fn C.libssh2_knownhost_writeline(knownhosts &C.LIBSSH2_KNOWNHOSTS, host &C.LIBSSH2_KNOWNHOST, buf voidptr, buflen usize, outlen &usize, typ int) int
fn C.libssh2_knownhost_addc(knownhosts &C.LIBSSH2_KNOWNHOSTS, host &char, salt &char, key &char, keylen usize, comment &char, commentlen usize, typemask int, store voidptr) int
fn C.libssh2_knownhost_checkp(knownhosts &C.LIBSSH2_KNOWNHOSTS, host &char, port int, key &char, keylen usize, typemask int, knownhost voidptr) int

// HostKeyType identifies the algorithm of a server host key. The values match
// the LIBSSH2_HOSTKEY_TYPE_* constants returned by `Session.hostkey()`.
pub enum HostKeyType {
	unknown
	rsa
	dss
	ecdsa_256
	ecdsa_384
	ecdsa_521
	ed25519
}

// KnownHostCheckResult represents the result of a known host check.
pub enum KnownHostCheckResult {
	match
	mismatch
	not_found
	failure
}

// KnownHosts manages known hosts for SSH server verification.
@[heap]
pub struct KnownHosts {
mut:
	handle  voidptr  = unsafe { nil }
	session &Session = unsafe { nil }
}

// new_knownhosts creates a new known hosts store for the given session.
pub fn (s &Session) new_knownhosts() !&KnownHosts {
	if isnil(s.handle) {
		return error('SSH session is closed')
	}
	handle := C.libssh2_knownhost_init(s.handle)
	if unsafe { handle == nil } {
		return error('Failed to initialize known hosts store')
	}
	return &KnownHosts{
		handle:  handle
		session: s
	}
}

// close frees the known hosts store. Calling it twice is safe.
pub fn (mut kh KnownHosts) close() {
	if unsafe { kh.handle != nil } {
		C.libssh2_knownhost_free(kh.handle)
		kh.handle = unsafe { nil }
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
// `typemask` is a combination of a host name type, a key encoding and a key
// algorithm, e.g. `knownhost_type_plain | knownhost_keyenc_raw | knownhost_key_ed25519`.
pub fn (kh &KnownHosts) add_host(host string, key []u8, typemask int) ! {
	rc := C.libssh2_knownhost_addc(kh.handle, &char(host.str), &char(unsafe { nil }),
		&char(key.data), key.len, &char(unsafe { nil }), 0, typemask, unsafe { nil })
	if rc != 0 {
		return ssh2_error(rc, kh.session)
	}
}

// check_host checks whether the given host+key matches the known hosts store.
// Returns KnownHostCheckResult.match if found and matching,
// KnownHostCheckResult.mismatch if found but different,
// KnownHostCheckResult.not_found if not in the store.
pub fn (kh &KnownHosts) check_host(host string, port int, key []u8, typemask int) !KnownHostCheckResult {
	rc := C.libssh2_knownhost_checkp(kh.handle, &char(host.str), port, &char(key.data),
		key.len, typemask, unsafe { nil })

	return match rc {
		0 { KnownHostCheckResult.match }
		1 { KnownHostCheckResult.mismatch }
		2 { KnownHostCheckResult.not_found }
		else { KnownHostCheckResult.failure }
	}
}

// ------------------------------------------------------------------
// Host key verification
// ------------------------------------------------------------------

// verify_host_key checks the host key presented by the server against
// `known_hosts_file` (an OpenSSH-format known_hosts file).
//
// When `add_if_missing` is true, an unknown-but-well-formed key is recorded in
// the file and treated as a match — the equivalent of OpenSSH's
// `StrictHostKeyChecking=accept-new`. When it is false, unknown hosts return
// `KnownHostCheckResult.not_found` and callers should refuse to continue.
pub fn (s &Session) verify_host_key(host string, port int, known_hosts_file string, add_if_missing bool) !KnownHostCheckResult {
	key, _, key_type := s.hostkey()
	if key.len == 0 {
		return error('SSH server did not present a host key')
	}
	if known_hosts_file == '' {
		return error('No known_hosts file given for host key verification')
	}

	typemask := knownhost_type_plain | knownhost_keyenc_raw | knownhost_key_flag(key_type)

	mut kh := s.new_knownhosts()!
	defer {
		kh.close()
	}

	if os.exists(known_hosts_file) {
		kh.read_file(known_hosts_file, knownhost_file_format_openssh)!
	}

	result := kh.check_host(host, port, key, typemask)!
	if result == .not_found && add_if_missing {
		kh.add_host(host, key, typemask)!
		parent := os.dir(known_hosts_file)
		if parent.len > 0 {
			os.mkdir_all(parent) or {}
		}
		kh.write_file(known_hosts_file, knownhost_file_format_openssh)!
		return KnownHostCheckResult.match
	}
	return result
}

// knownhost_key_flag converts the key type reported by `Session.hostkey()` into
// the LIBSSH2_KNOWNHOST_KEY_* flag used by the known-hosts API. The values are
// `HostKeyType` ordinals (LIBSSH2_HOSTKEY_TYPE_*).
pub fn knownhost_key_flag(hostkey_type int) int {
	return match hostkey_type {
		1 { knownhost_key_sshrsa } // rsa
		2 { knownhost_key_sshdss } // dss
		3 { knownhost_key_ecdsa_256 }
		4 { knownhost_key_ecdsa_384 }
		5 { knownhost_key_ecdsa_521 }
		6 { knownhost_key_ed25519 }
		else { knownhost_key_unknown }
	}
}

// ─── Constants ──────────────────────────────────────────────────────────

// Known-hosts file formats. libssh2 only supports the OpenSSH format.
pub const knownhost_file_format_openssh = 1

// Host name representation (LIBSSH2_KNOWNHOST_TYPE_*).
pub const knownhost_type_mask = 0xffff
pub const knownhost_type_plain = 1
pub const knownhost_type_sha1 = 2 // always base64 encoded
pub const knownhost_type_custom = 3

// Key encoding (LIBSSH2_KNOWNHOST_KEYENC_*).
pub const knownhost_keyenc_mask = 3 << 16
pub const knownhost_keyenc_raw = 1 << 16
pub const knownhost_keyenc_base64 = 2 << 16

// Key algorithms (LIBSSH2_KNOWNHOST_KEY_*). Combine one of these with a host
// name type and a key encoding, e.g.
// `knownhost_type_plain | knownhost_keyenc_raw | knownhost_key_ed25519`.
pub const knownhost_key_mask = 15 << 18
pub const knownhost_key_shift = 18
pub const knownhost_key_rsa1 = 1 << 18
pub const knownhost_key_sshrsa = 2 << 18
pub const knownhost_key_sshdss = 3 << 18
pub const knownhost_key_ecdsa_256 = 4 << 18
pub const knownhost_key_ecdsa_384 = 5 << 18
pub const knownhost_key_ecdsa_521 = 6 << 18
pub const knownhost_key_ed25519 = 7 << 18
pub const knownhost_key_unknown = 15 << 18
