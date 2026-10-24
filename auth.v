module vssh2

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_userauth_password(session &C.LIBSSH2_SESSION, username &char, password &char) int
fn C.libssh2_userauth_publickey_fromfile(session &C.LIBSSH2_SESSION, username &char, pubkey &char, privkey &char, passphrase &char) int
fn C.libssh2_userauth_publickey_frommemory(session &C.LIBSSH2_SESSION, username &char, username_len int, pubkeydata &char, pubkeydata_len int, privkeydata &char, privkeydata_len int, passphrase &char) int
// NOTE: the public `libssh2_userauth_hostbased_fromfile` is a 6-argument macro
// whose argument order differs from this `_ex` form. Using `_ex` directly keeps
// the wrapper's historical signature while passing every length explicitly.
fn C.libssh2_userauth_hostbased_fromfile_ex(session &C.LIBSSH2_SESSION, username &char, username_len int, pubkey &char, privkey &char, passphrase &char, hostname &char, hostname_len int, local_username &char, local_username_len int) int
// strdup is used for keyboard-interactive responses: libssh2 free()s that memory
// itself after the callback returns, so it must come from the C allocator.
fn C.strdup(s &char) &char
fn C.libssh2_userauth_keyboard_interactive(session &C.LIBSSH2_SESSION, username &char, response_handler fn (&C.LIBSSH2_SESSION, &&char, &&char, i32, &C.LIBSSH2_USERAUTH_KBDINT_PROMPT, &C.LIBSSH2_USERAUTH_KBDINT_RESPONSE, voidptr)) int
fn C.libssh2_userauth_list(session &C.LIBSSH2_SESSION, username &char, username_len int) &char
fn C.libssh2_userauth_authenticated(session &C.LIBSSH2_SESSION) int

// AuthMethod represents an authentication method supported by the server.
pub enum AuthMethod {
	password
	publickey
	hostbased
	keyboard_interactive
	none
	unknown
}

// ------------------------------------------------------------------
// Authentication
// ------------------------------------------------------------------

// auth_password authenticates using a password.
pub fn (s &Session) auth_password(username string, password string) ! {
	if isnil(s.handle) {
		return error('SSH session is closed')
	}
	rc := C.libssh2_userauth_password(s.handle, &char(username.str), &char(password.str))
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// auth_publickey_fromfile authenticates using a public key from files.
//   username:  the SSH username
//   pubkey:    path to the public key file. Pass an empty string to let libssh2
//              derive it from the private key.
//   privkey:   path to the private key file
//   passphrase: passphrase for the private key (empty when the key is unencrypted)
//
// libssh2 distinguishes NULL from "" for both `pubkey` and `passphrase`:
// an empty string for `pubkey` is treated as a filename and fails with
// "Unable to open public key file", so empty values are passed through as NULL.
pub fn (s &Session) auth_publickey_fromfile(username string, pubkey string, privkey string, passphrase string) ! {
	if isnil(s.handle) {
		return error('SSH session is closed')
	}
	if privkey == '' {
		return error('A private key file is required')
	}
	pubkey_ptr := if pubkey != '' { &char(pubkey.str) } else { &char(unsafe { nil }) }
	passphrase_ptr := if passphrase != '' { &char(passphrase.str) } else { &char(unsafe { nil }) }
	rc := C.libssh2_userauth_publickey_fromfile(s.handle, &char(username.str), pubkey_ptr,
		&char(privkey.str), passphrase_ptr)
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// auth_publickey_frommemory authenticates using a public key from memory buffers.
//   username:   the SSH username
//   pubkey_data:   public key data buffer (can be empty)
//   privkey_data:  private key data buffer
//   passphrase: passphrase for the private key (can be empty)
pub fn (s &Session) auth_publickey_frommemory(username string, pubkey_data []u8, privkey_data []u8, passphrase string) ! {
	if isnil(s.handle) {
		return error('SSH session is closed')
	}
	if privkey_data.len == 0 {
		return error('Private key data is required')
	}
	pubkey_ptr := if pubkey_data.len > 0 { &char(pubkey_data.data) } else { &char(unsafe { nil }) }
	pubkey_len := pubkey_data.len
	privkey_ptr := if privkey_data.len > 0 {
		&char(privkey_data.data)
	} else {
		&char(unsafe { nil })
	}
	privkey_len := privkey_data.len

	// libssh2 expects NULL (not "") when the key has no passphrase.
	passphrase_ptr := if passphrase != '' { &char(passphrase.str) } else { &char(unsafe { nil }) }
	rc := C.libssh2_userauth_publickey_frommemory(s.handle, &char(username.str), username.len,
		pubkey_ptr, pubkey_len, privkey_ptr, privkey_len, passphrase_ptr)
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// auth_hostbased_fromfile authenticates using host-based authentication.
//   username:      the remote account name
//   hostname:      the hostname the server should verify (the client host)
//   host_username: the local username to present; defaults to `username`
//   pubkey:        path to the public key file
//   privkey:       path to the private key file
//   passphrase:    passphrase for the private key (empty when unencrypted)
pub fn (s &Session) auth_hostbased_fromfile(username string, hostname string, host_username string, pubkey string, privkey string, passphrase string) ! {
	if isnil(s.handle) {
		return error('SSH session is closed')
	}
	if pubkey == '' || privkey == '' || hostname == '' {
		return error('host-based authentication requires pubkey, privkey and hostname')
	}
	local_user := if host_username != '' { host_username } else { username }
	passphrase_ptr := if passphrase != '' { &char(passphrase.str) } else { &char(unsafe { nil }) }
	rc := C.libssh2_userauth_hostbased_fromfile_ex(s.handle, &char(username.str), username.len,
		&char(pubkey.str), &char(privkey.str), passphrase_ptr, &char(hostname.str), hostname.len,
		&char(local_user.str), local_user.len)
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// ------------------------------------------------------------------
// Keyboard-interactive authentication - C struct type definitions
// ------------------------------------------------------------------

// C struct definitions for keyboard-interactive authentication.
// These mirror the libssh2 C types.
@[typedef]
struct C.LIBSSH2_USERAUTH_KBDINT_PROMPT {
	text   &char
	length u32
	echo   u8
}

@[typedef]
struct C.LIBSSH2_USERAUTH_KBDINT_RESPONSE {
	text   &char
	length u32
}

// auth_keyboard_interactive authenticates using keyboard-interactive method.
// The callback is invoked when the server sends a challenge.
// The callback receives prompt questions and echo flags, and should return responses.
pub fn (s &Session) auth_keyboard_interactive(username string, callback fn (questions []string, echoes []bool) []string) ! {
	if isnil(s.handle) {
		return error('SSH session is closed')
	}
	// V callback adapter for the C callback
	my_cb := fn [callback] (session &C.LIBSSH2_SESSION, name &&char, instruction &&char,
		num_prompts i32, prompts &C.LIBSSH2_USERAUTH_KBDINT_PROMPT,
		responses &C.LIBSSH2_USERAUTH_KBDINT_RESPONSE, abstract voidptr) {
		if num_prompts <= 0 {
			return
		}

		mut questions := []string{cap: int(num_prompts)}
		mut echoes := []bool{cap: int(num_prompts)}
		for i := 0; i < int(num_prompts); i++ {
			unsafe {
				questions << if prompts[i].text != nil {
					cstring_to_vstring(prompts[i].text)
				} else {
					''
				}
				echoes << (prompts[i].echo != 0)
			}
		}

		answers := callback(questions, echoes)

		for i := 0; i < int(num_prompts); i++ {
			if i >= answers.len || answers[i].len == 0 {
				unsafe {
					responses[i].text = &char(nil)
					responses[i].length = 0
				}
				continue
			}
			// libssh2 free()s the response buffers after this callback returns,
			// so hand it malloc-compatible memory, never a V string's buffer.
			unsafe {
				responses[i].text = C.strdup(answers[i].str)
				responses[i].length = u32(answers[i].len)
			}
		}
	}

	rc := C.libssh2_userauth_keyboard_interactive(s.handle, &char(username.str), my_cb)
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// auth_list returns a list of authentication methods available for the given username.
pub fn (s &Session) auth_list(username string) ![]AuthMethod {
	if isnil(s.handle) {
		return error('SSH session is closed')
	}
	ptr := C.libssh2_userauth_list(s.handle, &char(username.str), username.len)
	if unsafe { ptr == nil } {
		return ssh2_error(s.last_errno(), s)
	}
	methods_str := unsafe { cstring_to_vstring(ptr) }
	return parse_auth_methods(methods_str)
}

// is_authenticated returns true if the session has been successfully authenticated.
pub fn (s &Session) is_authenticated() bool {
	if isnil(s.handle) {
		return false
	}
	return C.libssh2_userauth_authenticated(s.handle) != 0
}

// ------------------------------------------------------------------
// Internal helpers
// ------------------------------------------------------------------

fn parse_auth_methods(methods_str string) []AuthMethod {
	mut methods := []AuthMethod{}
	for part in methods_str.split(',') {
		name := part.trim_space()
		if name.len == 0 {
			continue
		}
		methods << match name {
			'password' { AuthMethod.password }
			'publickey' { AuthMethod.publickey }
			'hostbased' { AuthMethod.hostbased }
			'keyboard-interactive' { AuthMethod.keyboard_interactive }
			'none' { AuthMethod.none }
			else { AuthMethod.unknown }
		}
	}
	return methods
}
