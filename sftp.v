module ssh2

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_sftp_init(session &C.LIBSSH2_SESSION) &C.LIBSSH2_SFTP
fn C.libssh2_sftp_shutdown(sftp &C.LIBSSH2_SFTP) int
fn C.libssh2_sftp_open_ex(sftp &C.LIBSSH2_SFTP, filename &char, filename_len int, flags u32, mode int, open_type int) &C.LIBSSH2_SFTP_HANDLE
fn C.libssh2_sftp_close_handle(handle &C.LIBSSH2_SFTP_HANDLE) int
fn C.libssh2_sftp_read(handle &C.LIBSSH2_SFTP_HANDLE, buf voidptr, buflen int) int
fn C.libssh2_sftp_write(handle &C.LIBSSH2_SFTP_HANDLE, buf voidptr, buflen int) int
fn C.libssh2_sftp_fstat_ex(handle &C.LIBSSH2_SFTP_HANDLE, st &C.LIBSSH2_SFTP_ATTRIBUTES, setstat int) int
fn C.libssh2_sftp_stat_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int, stat_type int, attrs &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_mkdir_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int, mode int) int
fn C.libssh2_sftp_rmdir_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int) int
fn C.libssh2_sftp_unlink_ex(sftp &C.LIBSSH2_SFTP, filename &char, filename_len int) int
fn C.libssh2_sftp_rename_ex(sftp &C.LIBSSH2_SFTP, source_filename &char, source_filename_len int, dest_filename &char, dest_filename_len int, flags int) int
fn C.libssh2_sftp_symlink_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int, target &char, target_len int, link_type int) int
fn C.libssh2_sftp_symlink_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int, target &char, target_len int, link_type int) int
fn C.libssh2_sftp_fsetstat(handle &C.LIBSSH2_SFTP_HANDLE, st &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_setstat(sftp &C.LIBSSH2_SFTP, filename &char, filename_len int, st &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_last_error(sftp &C.LIBSSH2_SFTP) int

// SFTP file open mode flags. Use bitwise OR (|) to combine flags:
// ```v
// sftp.open('file.txt', sftp_open_flag_read | sftp_open_flag_write, 0o644)!
// ```
pub const sftp_open_flag_read = 0x00000001
pub const sftp_open_flag_write = 0x00000002
pub const sftp_open_flag_append = 0x00000008
pub const sftp_open_flag_create = 0x00000010
pub const sftp_open_flag_trunc = 0x00000020
pub const sftp_open_flag_excl = 0x00000040

// SFTP attribute flags (internal, used for SftpAttrs.flags)
const sftp_attr_size = u64(1)
const sftp_attr_uidgid = u64(2)
const sftp_attr_permissions = u64(4)
const sftp_attr_modtime = u64(8)
const sftp_attr_allocsize = u64(16)

// SftpFileType represents the type of an SFTP file system entry.
pub enum SftpFileType {
	regular
	directory
	symlink
	special
	unknown
}

// SftpAttrs represents file attributes from SFTP.
pub struct SftpAttrs {
	flags       u64
	size        u64
	uid         u64
	gid         u64
	permissions u64
	atime       u64
	mtime       u64
}

// Internal C-compatible SFTP attributes struct (mirrors LIBSSH2_SFTP_ATTRIBUTES)
@[typedef]
struct C.LIBSSH2_SFTP_ATTRIBUTES {
	flags       u64
	filesize    u64
	uid         u64
	gid         u64
	permissions u64
	atime       u64
	mtime       u64
}

// SftpFile represents a file entry in an SFTP directory listing.
pub struct SftpFile {
	name      string
	long_name string
	attrs     SftpAttrs
}

// Sftp represents an SFTP session.
@[heap]
pub struct Sftp {
	handle         voidptr = unsafe { nil }
	session_handle voidptr = unsafe { nil }
}

// SftpFileHandle represents an open file handle for reading/writing.
pub struct SftpFileHandle {
	handle voidptr = unsafe { nil }
	sftp   &Sftp
}

// ------------------------------------------------------------------
// SFTP lifecycle
// ------------------------------------------------------------------

// init_sftp initializes an SFTP session over the authenticated transport.
pub fn (s &Session) init_sftp() !&Sftp {
	// First open a channel for SFTP
	ch := s.open_channel()!
	ch.subsystem('sftp') or {
		ch.close()
		return error('Failed to start SFTP subsystem')
	}
	ch.close() // channel is no longer needed once SFTP is initialized

	handle := C.libssh2_sftp_init(s.handle)
	if unsafe { handle == nil } {
		return ssh2_error(-1, s)
	}
	return &Sftp{
		handle:         handle
		session_handle: s.handle
	}
}

// close shuts down the SFTP session.
pub fn (sftp &Sftp) close() {
	if unsafe { sftp.handle != nil } {
		C.libssh2_sftp_shutdown(sftp.handle)
	}
}

// ------------------------------------------------------------------
// File operations
// ------------------------------------------------------------------

// open opens a remote file for reading or writing.
//   filename: path to the file on the remote server
//   flags: combination of sftp_open_flag_* values (e.g., `sftp_open_flag_read | sftp_open_flag_write`)
//   mode: permissions mode (e.g., `0o644`). Use 0 for default.
pub fn (sftp &Sftp) open(filename string, flags int, mode int) !&SftpFileHandle {
	handle := C.libssh2_sftp_open_ex(sftp.handle, &char(filename.str), filename.len, u32(flags),
		mode, 0)
	if unsafe { handle == nil } {
		return sftp_error(sftp)
	}
	return &SftpFileHandle{
		handle: handle
		sftp:   sftp
	}
}

// close closes an open file handle.
pub fn (fh &SftpFileHandle) close() {
	if unsafe { fh.handle != nil } {
		C.libssh2_sftp_close_handle(fh.handle)
	}
}

// read reads data from an open file.
// Returns the number of bytes read.
pub fn (fh &SftpFileHandle) read(buf []u8) !int {
	rc := C.libssh2_sftp_read(fh.handle, buf.data, buf.len)
	if rc < 0 {
		return sftp_error(fh.sftp)
	}
	return rc
}

// write writes data to an open file.
// Returns the number of bytes written.
pub fn (fh &SftpFileHandle) write(data []u8) !int {
	rc := C.libssh2_sftp_write(fh.handle, data.data, data.len)
	if rc < 0 {
		return sftp_error(fh.sftp)
	}
	return rc
}

// ------------------------------------------------------------------
// Directory operations
// ------------------------------------------------------------------

// readdir reads a directory entry (not yet implemented through this wrapper -
// use libssh2_sftp_readdir_ex if needed via direct C calls).
// For now, we provide stat and list via external commands.

// ------------------------------------------------------------------
// File information and operations
// ------------------------------------------------------------------

// stat retrieves file attributes for a given path.
pub fn (sftp &Sftp) stat(path string) !SftpAttrs {
	mut attrs := C.LIBSSH2_SFTP_ATTRIBUTES{}
	rc :=
		C.libssh2_sftp_stat_ex(sftp.handle, &char(path.str), path.len, 0, &attrs) // 0 = LIBSSH2_SFTP_STAT
	if rc != 0 {
		return sftp_error(sftp)
	}
	return sftp_attrs_from_c(attrs)
}

// setstat sets file attributes for a given path.
pub fn (sftp &Sftp) setstat(path string, attrs &SftpAttrs) ! {
	cattrs := sftp_attrs_to_c(attrs)
	rc := C.libssh2_sftp_setstat(sftp.handle, &char(path.str), path.len, &cattrs)
	if rc != 0 {
		return sftp_error(sftp)
	}
}

// mkdir creates a directory on the remote server.
pub fn (sftp &Sftp) mkdir(path string, mode u32) ! {
	rc := C.libssh2_sftp_mkdir_ex(sftp.handle, &char(path.str), path.len, int(mode))
	if rc != 0 {
		return sftp_error(sftp)
	}
}

// rmdir removes a directory on the remote server.
pub fn (sftp &Sftp) rmdir(path string) ! {
	rc := C.libssh2_sftp_rmdir_ex(sftp.handle, &char(path.str), path.len)
	if rc != 0 {
		return sftp_error(sftp)
	}
}

// unlink removes a file on the remote server.
pub fn (sftp &Sftp) unlink(path string) ! {
	rc := C.libssh2_sftp_unlink_ex(sftp.handle, &char(path.str), path.len)
	if rc != 0 {
		return sftp_error(sftp)
	}
}

// rename renames or moves a file on the remote server.
pub fn (sftp &Sftp) rename(src string, dest string) ! {
	rc :=
		C.libssh2_sftp_rename_ex(sftp.handle, &char(src.str), src.len, &char(dest.str), dest.len, 0)
	if rc != 0 {
		return sftp_error(sftp)
	}
}

// realpath resolves a path to its canonical form.
pub fn (sftp &Sftp) realpath(path string) !string {
	mut buf := [4096]u8{}
	rc :=
		C.libssh2_sftp_symlink_ex(sftp.handle, &char(path.str), path.len, &buf[0], 4096, 2) // 2 = LIBSSH2_SFTP_REALPATH
	if rc != 0 {
		return sftp_error(sftp)
	}
	return unsafe { cstring_to_vstring(&buf[0]) }
}

// ------------------------------------------------------------------
// Convenience: file transfer
// ------------------------------------------------------------------

// read_file reads the entire contents of a remote file.
pub fn (sftp &Sftp) read_file(path string) ![]u8 {
	fh := sftp.open(path, sftp_open_flag_read, 0o644)!
	defer {
		fh.close()
	}

	mut result := []u8{}
	mut buf := []u8{len: default_read_buffer_size}
	for {
		n := fh.read(buf) or { break }
		if n <= 0 {
			break
		}
		result << buf[..n]
	}
	return result
}

// write_file writes data to a remote file, creating or truncating it.
pub fn (sftp &Sftp) write_file(path string, data []u8) ! {
	fh := sftp.open(path, sftp_open_flag_write | sftp_open_flag_create | sftp_open_flag_trunc,
		0o644)!
	defer {
		fh.close()
	}

	mut offset := 0
	for offset < data.len {
		mut end := offset + default_write_buffer_size
		if end > data.len {
			end = data.len
		}
		n := fh.write(data[offset..end]) or { return error('SFTP write failed: ${err}') }
		offset += n
	}
}

// ------------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------------

fn sftp_attrs_from_c(attrs C.LIBSSH2_SFTP_ATTRIBUTES) SftpAttrs {
	return SftpAttrs{
		flags:       attrs.flags
		size:        attrs.filesize
		uid:         attrs.uid
		gid:         attrs.gid
		permissions: attrs.permissions
		atime:       attrs.atime
		mtime:       attrs.mtime
	}
}

fn sftp_attrs_to_c(attrs &SftpAttrs) C.LIBSSH2_SFTP_ATTRIBUTES {
	return C.LIBSSH2_SFTP_ATTRIBUTES{
		flags:       attrs.flags
		filesize:    attrs.size
		uid:         attrs.uid
		gid:         attrs.gid
		permissions: attrs.permissions
		atime:       attrs.atime
		mtime:       attrs.mtime
	}
}

fn sftp_error(sftp &Sftp) IError {
	err_code := C.libssh2_sftp_last_error(sftp.handle)
	msg := if unsafe { sftp.session_handle != nil } {
		mut cmsg := &char(unsafe { nil })
		mut msg_len := 0
		C.libssh2_session_last_error(sftp.session_handle, &cmsg, &msg_len, 0)
		unsafe { cstring_to_vstring(cmsg) }
	} else {
		'SFTP error ${err_code}'
	}
	return Ssh2Error{
		code:    err_code
		message: msg
	}
}
