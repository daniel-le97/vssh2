module ssh2

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_sftp_init(session &C.LIBSSH2_SESSION) &C.LIBSSH2_SFTP
fn C.libssh2_sftp_shutdown(sftp &C.LIBSSH2_SFTP) int
fn C.libssh2_sftp_open_ex(sftp &C.LIBSSH2_SFTP, filename &char, filename_len int, flags u32, mode int, open_type int) &C.LIBSSH2_SFTP_HANDLE
fn C.libssh2_sftp_close_handle(handle &C.LIBSSH2_SFTP_HANDLE) int
fn C.libssh2_sftp_read(handle &C.LIBSSH2_SFTP_HANDLE, buf voidptr, buflen int) int
fn C.libssh2_sftp_readdir_ex(handle &C.LIBSSH2_SFTP_HANDLE, buf &char, buflen usize, longentry &char, longentry_maxlen usize, attrs &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_write(handle &C.LIBSSH2_SFTP_HANDLE, buf voidptr, buflen int) int
fn C.libssh2_sftp_fstat_ex(handle &C.LIBSSH2_SFTP_HANDLE, st &C.LIBSSH2_SFTP_ATTRIBUTES, setstat int) int
fn C.libssh2_sftp_stat_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int, stat_type int, attrs &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_mkdir_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int, mode int) int
fn C.libssh2_sftp_rmdir_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int) int
fn C.libssh2_sftp_unlink_ex(sftp &C.LIBSSH2_SFTP, filename &char, filename_len int) int
fn C.libssh2_sftp_rename_ex(sftp &C.LIBSSH2_SFTP, source_filename &char, source_filename_len int, dest_filename &char, dest_filename_len int, flags int) int
fn C.libssh2_sftp_symlink_ex(sftp &C.LIBSSH2_SFTP, path &char, path_len int, target &char, target_len int, link_type int) int
fn C.libssh2_sftp_fsetstat(handle &C.LIBSSH2_SFTP_HANDLE, st &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_setstat(sftp &C.LIBSSH2_SFTP, filename &char, filename_len int, st &C.LIBSSH2_SFTP_ATTRIBUTES) int
fn C.libssh2_sftp_last_error(sftp &C.LIBSSH2_SFTP) int

// SFTP open types (the `open_type` argument of libssh2_sftp_open_ex).
const sftp_openfile = 0
const sftp_opendir = 1

// SFTP stat types (the `stat_type` argument of libssh2_sftp_stat_ex).
const sftp_stat = 0
const sftp_lstat = 1

// SFTP symlink_ex link types.
const sftp_symlink = 0
const sftp_readlink = 1
const sftp_realpath = 2

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

// SFTP attribute flags (the flag bits of SftpAttrs.flags).
// These mirror LIBSSH2_SFTP_ATTR_* from libssh2_sftp.h.
const sftp_attr_size = u64(1)
const sftp_attr_uidgid = u64(2)
const sftp_attr_permissions = u64(4)
// sftp_attr_acmodtime covers BOTH access and modification times (one flag).
const sftp_attr_acmodtime = u64(8)
const sftp_attr_extended = u64(0x80000000)

// SftpFileType represents the type of an SFTP file system entry.
pub enum SftpFileType {
	regular
	directory
	symlink
	special
	unknown
}

// POSIX file type mask and values (S_IFMT and friends).
const sftp_s_ifmt = u64(0o170000)
const sftp_s_ifdir = u64(0o040000)
const sftp_s_ifreg = u64(0o100000)
const sftp_s_iflnk = u64(0o120000)

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

// file_type derives the file type from the POSIX permission bits.
pub fn (a SftpAttrs) file_type() SftpFileType {
	return match a.permissions & sftp_s_ifmt {
		sftp_s_ifdir { SftpFileType.directory }
		sftp_s_ifreg { SftpFileType.regular }
		sftp_s_iflnk { SftpFileType.symlink }
		u64(0) { SftpFileType.unknown }
		else { SftpFileType.special }
	}
}

// mode returns the permission bits (lower 12 bits, i.e. rwx + setuid/gid/sticky).
pub fn (a SftpAttrs) mode() u32 {
	return u32(a.permissions & 0o7777)
}

// is_dir reports whether the entry is a directory.
pub fn (a SftpAttrs) is_dir() bool {
	return a.file_type() == .directory
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

// is_dir reports whether this directory entry is a directory.
pub fn (f SftpFile) is_dir() bool {
	return f.attrs.is_dir()
}

// is_symlink reports whether this directory entry is a symbolic link.
pub fn (f SftpFile) is_symlink() bool {
	return f.attrs.file_type() == .symlink
}

// Sftp represents an SFTP session.
@[heap]
pub struct Sftp {
mut:
	handle         voidptr = unsafe { nil }
	session_handle voidptr = unsafe { nil }
	closed         bool
}

// SftpFileHandle represents an open file handle for reading/writing.
@[heap]
pub struct SftpFileHandle {
mut:
	handle voidptr = unsafe { nil }
	sftp   &Sftp   = unsafe { nil }
	closed bool
}

// ------------------------------------------------------------------
// SFTP lifecycle
// ------------------------------------------------------------------

// init_sftp initializes an SFTP session over the authenticated transport.
//
// libssh2 opens and owns the SFTP channel internally, so there is no need to
// open (and immediately close) a subsystem channel first.
pub fn (s &Session) init_sftp() !&Sftp {
	handle := C.libssh2_sftp_init(s.handle)
	if unsafe { handle == nil } {
		return ssh2_error(s.last_errno(), s)
	}
	return &Sftp{
		handle:         handle
		session_handle: s.handle
	}
}

// close shuts down the SFTP session. Calling it twice is safe.
pub fn (mut sftp Sftp) close() {
	if sftp.closed {
		return
	}
	sftp.closed = true
	if unsafe { sftp.handle != nil } {
		C.libssh2_sftp_shutdown(sftp.handle)
		sftp.handle = unsafe { nil }
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
		mode, sftp_openfile)
	if unsafe { handle == nil } {
		return sftp_error(sftp)
	}
	return &SftpFileHandle{
		handle: handle
		sftp:   sftp
	}
}

// close closes an open file handle. Calling it twice is safe.
pub fn (mut fh SftpFileHandle) close() {
	if fh.closed {
		return
	}
	fh.closed = true
	if unsafe { fh.handle != nil } {
		C.libssh2_sftp_close_handle(fh.handle)
		fh.handle = unsafe { nil }
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

// stat retrieves file attributes for a given path. Symbolic links are followed;
// use `lstat` to inspect the link itself.
pub fn (sftp &Sftp) stat(path string) !SftpAttrs {
	return sftp.stat_ex(path, sftp_stat)
}

// lstat retrieves file attributes for a given path without following symlinks.
pub fn (sftp &Sftp) lstat(path string) !SftpAttrs {
	return sftp.stat_ex(path, sftp_lstat)
}

fn (sftp &Sftp) stat_ex(path string, stat_type int) !SftpAttrs {
	mut attrs := C.LIBSSH2_SFTP_ATTRIBUTES{}
	rc := C.libssh2_sftp_stat_ex(sftp.handle, &char(path.str), path.len, stat_type, &attrs)
	if rc != 0 {
		return sftp_error(sftp)
	}
	return sftp_attrs_from_c(attrs)
}

// exists reports whether `path` exists on the remote server.
pub fn (sftp &Sftp) exists(path string) bool {
	_ := sftp.stat(path) or { return false }
	return true
}

// chmod changes the permission bits of a remote file or directory.
pub fn (sftp &Sftp) chmod(path string, mode u32) ! {
	mut attrs := SftpAttrs{
		flags:       sftp_attr_permissions
		permissions: u64(mode)
	}
	return sftp.setstat(path, &attrs)
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
	mut buf := []u8{len: 4096}
	rc := C.libssh2_sftp_symlink_ex(sftp.handle, &char(path.str), path.len, &char(buf.data),
		buf.len, sftp_realpath)
	if rc < 0 {
		return sftp_error(sftp)
	}
	return unsafe { buf[..rc].bytestr() }
}

// readlink returns the target of a symbolic link.
pub fn (sftp &Sftp) readlink(path string) !string {
	mut buf := []u8{len: 4096}
	rc := C.libssh2_sftp_symlink_ex(sftp.handle, &char(path.str), path.len, &char(buf.data),
		buf.len, sftp_readlink)
	if rc < 0 {
		return sftp_error(sftp)
	}
	return unsafe { buf[..rc].bytestr() }
}

// symlink creates a symbolic link at `path` pointing to `target`.
pub fn (sftp &Sftp) symlink(target string, path string) ! {
	rc := C.libssh2_sftp_symlink_ex(sftp.handle, &char(target.str), target.len,
		&char(path.str), path.len, sftp_symlink)
	if rc != 0 {
		return sftp_error(sftp)
	}
}

// ------------------------------------------------------------------
// Directory listing
// ------------------------------------------------------------------

// list_dir returns the entries of a remote directory.
// The entries `"."` and `".."` are skipped.
pub fn (sftp &Sftp) list_dir(path string) ![]SftpFile {
	handle := C.libssh2_sftp_open_ex(sftp.handle, &char(path.str), path.len, 0, 0, sftp_opendir)
	if unsafe { handle == nil } {
		return sftp_error(sftp)
	}
	defer {
		C.libssh2_sftp_close_handle(handle)
	}

	mut files := []SftpFile{}
	mut name_buf := []u8{len: 4096}
	for {
		mut attrs := C.LIBSSH2_SFTP_ATTRIBUTES{}
		rc := C.libssh2_sftp_readdir_ex(handle, &char(name_buf.data), name_buf.len,
			&char(unsafe { nil }), 0, &attrs)
		if rc == 0 {
			break // end of directory
		}
		if rc < 0 {
			return sftp_error(sftp)
		}
		name := unsafe { name_buf[..rc].bytestr() }
		if name == '.' || name == '..' {
			continue
		}
		files << SftpFile{
			name:  name
			attrs: sftp_attrs_from_c(attrs)
		}
	}
	return files
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
