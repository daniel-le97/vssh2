module ssh2

import strings
import time

// Polling backoff bounds used while waiting for command output.
const exec_pause_min_ms = 1
const exec_pause_max_ms = 50

// ------------------------------------------------------------------
// Command execution
// ------------------------------------------------------------------
// All of these run a command on a session channel and collect its output.
//
// They use non-blocking, multiplexed reads (see `Channel.pump`) so that a
// command writing to both stdout and stderr cannot deadlock the connection and
// so callers can observe output live. The previous approach — read stdout to
// EOF, then read stderr — blocked until the command finished (or forever, once
// the remote filled the ~2 MB channel window on the stream nobody was reading),
// which is exactly the case for `docker build` log streaming.

// ------------------------------------------------------------------
// Output sinks
// ------------------------------------------------------------------
// IMPORTANT: V silently drops the captured variables of a closure that is
// passed through a plain `fn (...)` parameter. A capturing closure therefore
// CANNOT be used to accumulate output — the writes go to a discarded copy:
//
// ```v
// mut lines := []string{}
// session.run_stream('ls', fn [mut lines] (chunk string) { lines << chunk })
// // lines is still empty!
// ```
//
// Use `ChunkSink`, or better `Session.start()` + `ExecProcess.pump()`, whenever
// the receiver has state to keep.

// ChunkSink receives command output as it arrives. Interface values keep their
// receiver (unlike plain function parameters), so a sink can hold a file, a
// database handle or an accumulator.
//
// ```v
// struct LogFile {
// mut:
// 	file os.File
// }
//
// fn (mut l LogFile) write(chunk string) {
// 	l.file.write_string(chunk) or {}
// }
// ```
pub interface ChunkSink {
mut:
	write(chunk string)
}

// FnSink adapts a plain, stateless function to ChunkSink.
struct FnSink {
	cb fn (string) = unsafe { nil }
}

fn (mut f FnSink) write(chunk string) {
	f.cb(chunk)
}

// DiscardSink drops everything; used by the buffered entry points.
struct DiscardSink {}

fn (mut d DiscardSink) write(_ string) {}

// ExecResult is the outcome of running a command over an SSH channel.
pub struct ExecResult {
pub:
	exit_code int
	stdout    string
	stderr    string
}

// output returns stdout followed by stderr. Many tools (docker, git) write
// progress and logs to stderr, so this is the closest thing to what a user would
// see in a terminal.
pub fn (r ExecResult) output() string {
	if r.stderr.len == 0 {
		return r.stdout
	}
	if r.stdout.len == 0 {
		return r.stderr
	}
	return r.stdout + r.stderr
}

// ok reports whether the command exited with status 0.
pub fn (r ExecResult) ok() bool {
	return r.exit_code == 0
}

// ------------------------------------------------------------------
// Caller-driven streaming
// ------------------------------------------------------------------

// ExecProcess is a running remote command whose output the caller drains.
//
// This is the API to use when the consumer keeps state (writing a log file,
// appending to a database, feeding a WebSocket): no callbacks are involved, so
// nothing depends on V's closure semantics.
//
// ```v
// mut proc := session.start('docker build ...') or { return }
// defer { proc.kill() }
// for {
// 	out := proc.pump() or { break }
// 	log.append(out.stdout)
// 	log.append(out.stderr)
// 	if out.eof {
// 		break
// 	}
// 	time.sleep(100 * time.millisecond)
// }
// code := proc.finish() or { return }
// ```
pub struct ExecProcess {
mut:
	session      &Session = unsafe { nil }
	channel      &Channel = unsafe { nil }
	was_blocking bool
	finished     bool
	final_code   int = -1
}

// start opens a channel, runs `cmd`, and switches the session to non-blocking
// mode so `pump` can be called repeatedly. Call `finish` (or `kill`) when done.
pub fn (s &Session) start(cmd string) !&ExecProcess {
	mut ch := s.open_channel()!
	ch.exec(cmd) or {
		ch.close()
		return err
	}
	was_blocking := s.is_blocking()
	s.set_blocking(false)
	return &ExecProcess{
		session:      s
		channel:      ch
		was_blocking: was_blocking
	}
}

// pump returns whatever output is available right now.
// `eof` becomes true once both streams have finished; when a call returns no
// bytes and `eof` is false, sleep briefly (or wait on the socket) before
// pumping again.
pub fn (mut p ExecProcess) pump() !PumpResult {
	if p.finished {
		return PumpResult{
			eof: true
		}
	}
	return p.channel.pump()
}

// finish waits for the command to exit and returns its exit code. It restores
// the session's blocking mode and closes the channel. Calling it twice is safe.
pub fn (mut p ExecProcess) finish() !int {
	if p.finished {
		return p.final_code
	}
	p.finished = true
	// Restore blocking I/O first: in non-blocking mode wait_closed() returns
	// EAGAIN and the exit status would never be received.
	p.session.set_blocking(true)
	p.channel.wait_eof() or {}
	p.channel.wait_closed() or {}
	p.final_code = p.channel.exit_status()
	p.channel.close()
	p.session.set_blocking(p.was_blocking)
	return p.final_code
}

// kill abandons a command that is still running and releases the channel.
pub fn (mut p ExecProcess) kill() {
	if p.finished {
		return
	}
	p.finished = true
	p.channel.close()
	p.session.set_blocking(p.was_blocking)
}

// exit_code returns the exit code recorded by finish() (-1 before that).
pub fn (p &ExecProcess) exit_code() int {
	return p.final_code
}

// ------------------------------------------------------------------
// Buffered / callback entry points
// ------------------------------------------------------------------

// exec_and_read runs `cmd` and returns its stdout and stderr separately.
pub fn (s &Session) exec_and_read(cmd string) !(string, string) {
	res := s.run(cmd)!
	return res.stdout, res.stderr
}

// run executes `cmd` and returns its output once the command completes.
pub fn (s &Session) run(cmd string) !ExecResult {
	mut a := DiscardSink{}
	mut b := DiscardSink{}
	return s.exec_core(cmd, 0, mut a, mut b)
}

// run_timeout is `run` with an idle timeout: the command is abandoned when it
// has produced no output at all for `idle_timeout_ms` milliseconds.
// `0` (the default everywhere else) waits indefinitely.
pub fn (s &Session) run_timeout(cmd string, idle_timeout_ms int) !ExecResult {
	mut a := DiscardSink{}
	mut b := DiscardSink{}
	return s.exec_core(cmd, idle_timeout_ms, mut a, mut b)
}

// run_stream executes `cmd` and calls `on_output` with output chunks as they
// arrive, for both stdout and stderr, in arrival order.
//
// `on_output` must be a plain, stateless function: V drops closure state at the
// `fn (...)` boundary, so pass a `ChunkSink` to `run_sink` or use `start()` when
// the receiver needs to remember anything.
pub fn (s &Session) run_stream(cmd string, on_output fn (string)) !ExecResult {
	mut out_sink := FnSink{
		cb: on_output
	}
	mut err_sink := FnSink{
		cb: on_output
	}
	return s.exec_core(cmd, 0, mut out_sink, mut err_sink)
}

// run_stream_timeout is `run_stream` with an idle timeout (0 = none).
pub fn (s &Session) run_stream_timeout(cmd string, on_output fn (string), idle_timeout_ms int) !ExecResult {
	mut out_sink := FnSink{
		cb: on_output
	}
	mut err_sink := FnSink{
		cb: on_output
	}
	return s.exec_core(cmd, idle_timeout_ms, mut out_sink, mut err_sink)
}

// run_stream_split is like `run_stream` but keeps the two streams separate.
pub fn (s &Session) run_stream_split(cmd string, on_stdout fn (string), on_stderr fn (string)) !ExecResult {
	mut out_sink := FnSink{
		cb: on_stdout
	}
	mut err_sink := FnSink{
		cb: on_stderr
	}
	return s.exec_core(cmd, 0, mut out_sink, mut err_sink)
}

// run_sink executes `cmd`, forwarding stdout and stderr to `sink` in arrival
// order. Unlike `run_stream`, the sink keeps its state.
pub fn (s &Session) run_sink(cmd string, mut sink ChunkSink) !ExecResult {
	mut out_sink := sink
	mut err_sink := sink
	return s.exec_core(cmd, 0, mut out_sink, mut err_sink)
}

// run_sink_timeout is `run_sink` with an idle timeout: the command is abandoned
// when it has produced no output at all for `idle_timeout_ms` milliseconds.
// `0` waits indefinitely.
pub fn (s &Session) run_sink_timeout(cmd string, mut sink ChunkSink, idle_timeout_ms int) !ExecResult {
	mut out_sink := sink
	mut err_sink := sink
	return s.exec_core(cmd, idle_timeout_ms, mut out_sink, mut err_sink)
}

// exec_core is the shared implementation behind the entry points above.
fn (s &Session) exec_core(cmd string, idle_timeout_ms int, mut out_sink ChunkSink, mut err_sink ChunkSink) !ExecResult {
	mut proc := s.start(cmd)!
	mut completed := false
	defer {
		if !completed {
			proc.kill()
		}
	}

	mut out_sb := strings.Builder{}
	mut err_sb := strings.Builder{}
	mut last_activity := time.now()
	mut stream_error := ''
	// Backoff used while waiting for output: output is picked up within a
	// millisecond while it is flowing, and an idle command costs almost no CPU.
	mut pause_ms := exec_pause_min_ms

	for {
		result := proc.pump() or {
			stream_error = err.msg()
			PumpResult{
				eof: true
			}
		}
		if result.stdout.len > 0 {
			out_sb.write_string(result.stdout)
			out_sink.write(result.stdout)
		}
		if result.stderr.len > 0 {
			err_sb.write_string(result.stderr)
			err_sink.write(result.stderr)
		}
		if result.bytes > 0 {
			last_activity = time.now()
			pause_ms = exec_pause_min_ms
			continue
		}
		if result.eof {
			break
		}
		// Nothing to read right now: yield before polling again.
		mut wait_ms := pause_ms
		if idle_timeout_ms > 0 {
			elapsed := int((time.now() - last_activity).milliseconds())
			remaining := idle_timeout_ms - elapsed
			if remaining <= 0 {
				return error('command produced no output for ${idle_timeout_ms}ms; giving up')
			}
			if remaining < wait_ms {
				wait_ms = remaining
			}
		}
		if wait_ms > 0 {
			time.sleep(wait_ms * time.millisecond)
		}
		if pause_ms < exec_pause_max_ms {
			pause_ms *= 2
		}
	}

	exit_code := proc.finish()!
	completed = true

	stdout := out_sb.str()
	stderr := err_sb.str()
	if stream_error.len > 0 && stdout.len == 0 && stderr.len == 0 {
		return error('SSH command failed: ${stream_error}')
	}
	return ExecResult{
		exit_code: exit_code
		stdout:    stdout
		stderr:    stderr
	}
}
