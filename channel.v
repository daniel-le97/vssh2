module ssh2

import strings
import time

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
fn C.libssh2_channel_set_blocking(channel &C.LIBSSH2_CHANNEL, blocking int)
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

// pump_max_bytes_per_stream caps how much one pump() call reads from a single
// stream, so a busy stdout cannot starve stderr.
const pump_max_bytes_per_stream = 262144

// Channel represents an SSH channel for executing commands, starting shells, etc.
@[heap]
pub struct Channel {
mut:
	handle         voidptr = unsafe { nil }
	session_handle voidptr = unsafe { nil }
	closed         bool
	// Per-stream EOF flags tracked by pump().
	stdout_eof bool
	stderr_eof bool
	// Reusable read buffers (avoid an allocation per pump() call).
	read_buf []u8
	err_buf  []u8
}

// PumpResult is the outcome of a single non-blocking `Channel.pump()` call.
pub struct PumpResult {
pub mut:
	stdout string
	stderr string
	// bytes is the total number of bytes read by this call.
	bytes int
	// eof is true once both streams have signalled end-of-file.
	eof bool
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

// close closes the channel and frees its resources. Calling it twice is safe.
pub fn (mut ch Channel) close() {
	if ch.closed {
		return
	}
	ch.closed = true
	if unsafe { ch.handle != nil } {
		C.libssh2_channel_close(ch.handle)
		C.libssh2_channel_free(ch.handle)
		ch.handle = unsafe { nil }
	}
}

// set_blocking switches this channel between blocking and non-blocking I/O.
// In non-blocking mode reads return `error_eagain` instead of waiting for data.
pub fn (ch &Channel) set_blocking(blocking bool) {
	C.libssh2_channel_set_blocking(ch.handle, if blocking { 1 } else { 0 })
}

// ------------------------------------------------------------------
// Non-blocking multiplexed reads
// ------------------------------------------------------------------

// pump reads whatever is available on stdout and stderr right now and returns
// it in arrival order per stream.
//
// This is the safe way to consume a command's output: reading one stream to EOF
// before touching the other deadlocks as soon as the remote fills the channel
// window (~2 MB) on the stream you are not reading — which is exactly what
// happens when `docker build` writes a large log to stderr.
//
// The session must be in non-blocking mode (`Session.set_blocking(false)`).
// Returns `eof: true` once both streams are done; callers should wait on
// `Session.wait_socket()` when a call returns no bytes and `eof` is false.
pub fn (mut ch Channel) pump() !PumpResult {
	if unsafe { ch.handle == nil } {
		return PumpResult{
			eof: true
		}
	}
	if ch.read_buf.len == 0 {
		ch.read_buf = []u8{len: default_read_buffer_size}
		ch.err_buf = []u8{len: default_read_buffer_size}
	}

	mut out_sb := strings.Builder{}
	mut err_sb := strings.Builder{}
	mut result := PumpResult{}

	if !ch.stdout_eof {
		mut drained := 0
		for drained < pump_max_bytes_per_stream {
			rc := C.libssh2_channel_read_ex(ch.handle, stream_stdout, ch.read_buf.data,
				ch.read_buf.len)
			if rc > 0 {
				out_sb.write_string(unsafe { ch.read_buf[..rc].bytestr() })
				result.bytes += rc
				drained += rc
				continue
			}
			if rc == 0 {
				ch.stdout_eof = true
				break
			}
			if rc == error_eagain {
				break
			}
			return channel_error(rc, ch.session_handle)
		}
	}

	if !ch.stderr_eof {
		mut drained := 0
		for drained < pump_max_bytes_per_stream {
			rc := C.libssh2_channel_read_ex(ch.handle, stream_stderr, ch.err_buf.data,
				ch.err_buf.len)
			if rc > 0 {
				err_sb.write_string(unsafe { ch.err_buf[..rc].bytestr() })
				result.bytes += rc
				drained += rc
				continue
			}
			if rc == 0 {
				ch.stderr_eof = true
				break
			}
			if rc == error_eagain {
				break
			}
			return channel_error(rc, ch.session_handle)
		}
	}

	result.stdout = out_sb.str()
	result.stderr = err_sb.str()
	result.eof = ch.stdout_eof && ch.stderr_eof
	return result
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

// write_all writes `data` to the channel's stdin stream, retrying partial
// writes (and EAGAIN in non-blocking mode) until every byte has been sent.
// This matters for payloads larger than one SSH packet.
pub fn (ch &Channel) write_all(data []u8) ! {
	mut offset := 0
	for offset < data.len {
		rc := C.libssh2_channel_write_ex(ch.handle, stream_stdout, data[offset..].data,
			data.len - offset)
		if rc == error_eagain {
			// Non-blocking session with a full window: yield briefly instead of
			// spinning. Blocking sessions never hit this path.
			time.sleep(1 * time.millisecond)
			continue
		}
		if rc < 0 {
			return channel_error(rc, ch.session_handle)
		}
		offset += rc
	}
}

// write_string_all writes a whole string to the channel's stdin stream.
pub fn (ch &Channel) write_string_all(data string) ! {
	return ch.write_all(data.bytes())
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
	mut msg := ''
	if unsafe { session_handle != nil } {
		mut cmsg := &char(unsafe { nil })
		mut msg_len := 0
		C.libssh2_session_last_error(session_handle, &cmsg, &msg_len, 0)
		if unsafe { cmsg != nil } {
			msg = unsafe { cstring_to_vstring(cmsg) }
		}
	}
	if msg.len == 0 {
		msg = socket_error_message(code)
	}
	return Ssh2Error{
		code:    code
		message: msg
	}
}

// ------------------------------------------------------------------
// Convenience: execute a command and collect output
// ------------------------------------------------------------------
// See exec.v — `Session.exec_and_read()`, `Session.run()` and
// `Session.run_stream()` are defined there. They use the non-blocking `pump()`
// above so that a command writing to stderr cannot deadlock the connection.
