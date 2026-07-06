module ssh2

#include <libssh2.h>

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_channel_open_ex(session &C.LIBSSH2_SESSION, channel_type &char, channel_type_len int, window_size int, packet_size int, message &char, message_len int) &C.LIBSSH2_CHANNEL
fn C.libssh2_channel_open_session(session &C.LIBSSH2_SESSION) &C.LIBSSH2_CHANNEL
fn C.libssh2_channel_free(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_exec(channel &C.LIBSSH2_CHANNEL, command &char) int
fn C.libssh2_channel_shell(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_subsystem(channel &C.LIBSSH2_CHANNEL, subsystem &char) int
fn C.libssh2_channel_read_ex(channel &C.LIBSSH2_CHANNEL, stream_id int, buf voidptr, buflen int) int
fn C.libssh2_channel_write_ex(channel &C.LIBSSH2_CHANNEL, stream_id int, buf voidptr, buflen int) int
fn C.libssh2_channel_send_eof(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_eof(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_wait_eof(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_close(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_wait_closed(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_get_exit_status(channel &C.LIBSSH2_CHANNEL) int
fn C.libssh2_channel_setenv(channel &C.LIBSSH2_CHANNEL, varname &char, varname_len int, value &char, value_len int) int
fn C.libssh2_channel_request_pty(channel &C.LIBSSH2_CHANNEL, term &char) int
fn C.libssh2_channel_request_pty_ex(channel &C.LIBSSH2_CHANNEL, term &char, term_len int, modes &char, modes_len int, width int, height int, width_px int, height_px int) int
fn C.libssh2_channel_x11_req(channel &C.LIBSSH2_CHANNEL, screen_number int) int
fn C.libssh2_channel_process_startup(channel &C.LIBSSH2_CHANNEL, request &char, request_len int, message &char, message_len int) int
fn C.libssh2_channel_flush_ex(channel &C.LIBSSH2_CHANNEL, streamid int) int
fn C.libssh2_channel_window_read_ex(channel &C.LIBSSH2_CHANNEL, read_avail &int, window_size_initial &int) int
fn C.libssh2_channel_window_write_ex(channel &C.LIBSSH2_CHANNEL, window_size_initial &int) int

// Stream identifiers for reading/writing
const stream_stdout = 0
const stream_stderr = 1

// ChannelType represents the type of channel.
pub enum ChannelType {
	session
	direct_tcpip
	direct_streamlocal
	forwarded_tcpip
	forwarded_streamlocal
}

// Channel represents an SSH channel for executing commands, starting shells, etc.
pub struct Channel {
	handle         voidptr     = unsafe { nil }
	session_handle voidptr     = unsafe { nil }
	channel_type   ChannelType = ChannelType.session
}

// ------------------------------------------------------------------
// Channel lifecycle
// ------------------------------------------------------------------

// open_session opens a new session channel.
pub fn (s &Session) open_channel() !&Channel {
	handle := C.libssh2_channel_open_session(s.handle)
	if unsafe { handle == nil } {
		return ssh2_error(-1, s)
	}
	return &Channel{
		handle:         handle
		session_handle: s.handle
	}
}

// close closes the channel and frees its resources.
pub fn (ch &Channel) close() {
	if unsafe { ch.handle != nil } {
		C.libssh2_channel_close(ch.handle)
		C.libssh2_channel_free(ch.handle)
	}
}

// ------------------------------------------------------------------
// Command execution
// ------------------------------------------------------------------

// exec executes a command on the remote host via this channel.
pub fn (ch &Channel) exec(command string) ! {
	rc := C.libssh2_channel_exec(ch.handle, &char(command.str))
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// shell starts a shell on the remote host via this channel.
pub fn (ch &Channel) shell() ! {
	rc := C.libssh2_channel_shell(ch.handle)
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// subsystem requests a subsystem on the remote host (e.g., "sftp").
pub fn (ch &Channel) subsystem(subsystem_name string) ! {
	rc := C.libssh2_channel_subsystem(ch.handle, &char(subsystem_name.str))
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// ------------------------------------------------------------------
// Reading and writing
// ------------------------------------------------------------------

// read reads data from the channel's stdout stream.
// Returns the number of bytes read, or 0 on EOF.
pub fn (ch &Channel) read(buf []u8) !int {
	rc := C.libssh2_channel_read_ex(ch.handle, stream_stdout, buf.data, buf.len)
	if rc < 0 {
		return channel_error(rc, ch.session_handle)
	}
	return rc
}

// read_stderr reads data from the channel's stderr stream.
pub fn (ch &Channel) read_stderr(buf []u8) !int {
	rc := C.libssh2_channel_read_ex(ch.handle, stream_stderr, buf.data, buf.len)
	if rc < 0 {
		return channel_error(rc, ch.session_handle)
	}
	return rc
}

// write writes data to the channel's stdin stream.
// Returns the number of bytes written.
pub fn (ch &Channel) write(data []u8) !int {
	rc := C.libssh2_channel_write_ex(ch.handle, 0, data.data, data.len)
	if rc < 0 {
		return channel_error(rc, ch.session_handle)
	}
	return rc
}

// write_string writes a string to the channel's stdin stream.
pub fn (ch &Channel) write_string(data string) !int {
	return ch.write(data.bytes())
}

// ------------------------------------------------------------------
// Channel state
// ------------------------------------------------------------------

// send_eof sends an EOF on this channel.
pub fn (ch &Channel) send_eof() ! {
	rc := C.libssh2_channel_send_eof(ch.handle)
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// eof returns true if the remote side has sent EOF.
pub fn (ch &Channel) eof() bool {
	return C.libssh2_channel_eof(ch.handle) != 0
}

// wait_eof blocks until the remote side sends EOF.
pub fn (ch &Channel) wait_eof() ! {
	rc := C.libssh2_channel_wait_eof(ch.handle)
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// wait_closed blocks until the channel is closed.
pub fn (ch &Channel) wait_closed() ! {
	rc := C.libssh2_channel_wait_closed(ch.handle)
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// exit_status returns the exit code of the remote command.
pub fn (ch &Channel) exit_status() int {
	return C.libssh2_channel_get_exit_status(ch.handle)
}

// ------------------------------------------------------------------
// PTY and environment
// ------------------------------------------------------------------

// request_pty requests a pseudo-terminal on this channel.
pub fn (ch &Channel) request_pty(term string) ! {
	rc := C.libssh2_channel_request_pty(ch.handle, &char(term.str))
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// request_pty_size requests a pseudo-terminal with specific dimensions.
pub fn (ch &Channel) request_pty_size(term string, width int, height int) ! {
	rc := C.libssh2_channel_request_pty_ex(ch.handle, &char(term.str), term.len,
		&char(unsafe { nil }), 0, width, height, 0, 0)
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// setenv sets an environment variable on the remote channel.
pub fn (ch &Channel) setenv(name string, value string) ! {
	rc := C.libssh2_channel_setenv(ch.handle, &char(name.str), name.len, &char(value.str),
		value.len)
	if rc != 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// ------------------------------------------------------------------
// Flush
// ------------------------------------------------------------------

// flush flushes the channel's stdout stream.
pub fn (ch &Channel) flush() ! {
	rc := C.libssh2_channel_flush_ex(ch.handle, stream_stdout)
	if rc < 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// flush_stderr flushes the channel's stderr stream.
pub fn (ch &Channel) flush_stderr() ! {
	rc := C.libssh2_channel_flush_ex(ch.handle, stream_stderr)
	if rc < 0 {
		return channel_error(rc, ch.session_handle)
	}
}

// ------------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------------

// channel_error creates an IError from a libssh2 error code using a raw session handle.
fn channel_error(code int, session_handle &C.LIBSSH2_SESSION) IError {
	msg := if unsafe { session_handle != nil } {
		mut cmsg := &char(unsafe { nil })
		mut msg_len := 0
		C.libssh2_session_last_error(session_handle, &cmsg, &msg_len, 0)
		unsafe { cstring_to_vstring(cmsg) }
	} else {
		socket_error_message(code)
	}
	return Ssh2Error{
		code:    code
		message: msg
	}
}

// ------------------------------------------------------------------
// Convenience: execute a command and collect output
// ------------------------------------------------------------------

// exec_and_read executes a command, reads all stdout and stderr, and returns them.
// This is a high-level convenience method.
pub fn (s &Session) exec_and_read(command string) !(string, string) {
	ch := s.open_channel()!
	defer {
		ch.close()
	}

	ch.exec(command)!

	// Read all stdout
	mut stdout_buf := []u8{len: default_read_buffer_size}
	mut stdout_result := ''
	for {
		n := ch.read(stdout_buf) or { break }
		if n <= 0 {
			break
		}
		stdout_result += unsafe { stdout_buf[..n].bytestr() }
	}

	// Read all stderr
	mut stderr_buf := []u8{len: default_read_buffer_size}
	mut stderr_result := ''
	for {
		n := ch.read_stderr(stderr_buf) or { break }
		if n <= 0 {
			break
		}
		stderr_result += unsafe { stderr_buf[..n].bytestr() }
	}

	ch.wait_eof()!
	ch.wait_closed()!

	return stdout_result, stderr_result
}
