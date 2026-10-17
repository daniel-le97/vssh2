module ssh2

// ------------------------------------------------------------------
// C function declarations
// ------------------------------------------------------------------

fn C.libssh2_userauth_password(session &C.LIBSSH2_SESSION, username &char, password &char) int
fn C.libssh2_userauth_publickey_fromfile(session &C.LIBSSH2_SESSION, username &char, pubkey &char, privkey &char, passphrase &char) int
fn C.libssh2_userauth_publickey_frommemory(session &C.LIBSSH2_SESSION, username &char, username_len int, pubkeydata &char, pubkeydata_len int, privkeydata &char, privkeydata_len int, passphrase &char) int
fn C.libssh2_userauth_hostbased_fromfile(session &C.LIBSSH2_SESSION, username &char, hostname &char, host_username &char, pubkey &char, privkey &char, passphrase &char) int
fn C.libssh2_userauth_keyboard_interactive(session &C.LIBSSH2_SESSION, username &char, response_handler fn (&C.LIBSSH2_SESSION, &&char, &&char, i32, &C.LIBSSH2_USERAUTH_KBD_INT_PROMPT, &C.LIBSSH2_USERAUTH_KBD_INT_RESPONSE, voidptr)) int
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
	pubkey_ptr := if pubkey.len > 0 { &char(pubkey.str) } else { &char(unsafe { nil }) }
	passphrase_ptr := if passphrase.len > 0 { &char(passphrase.str) } else { &char(unsafe { nil }) }
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
	pubkey_ptr := if pubkey_data.len > 0 { &char(pubkey_data.data) } else { &char(unsafe { nil }) }
	pubkey_len := pubkey_data.len
	privkey_ptr := if privkey_data.len > 0 {
		&char(privkey_data.data)
	} else {
		&char(unsafe { nil })
	}
	privkey_len := privkey_data.len

	rc := C.libssh2_userauth_publickey_frommemory(s.handle, &char(username.str), username.len,
		pubkey_ptr, pubkey_len, privkey_ptr, privkey_len, &char(passphrase.str))
	if rc != 0 {
		return ssh2_error(rc, s)
	}
}

// auth_hostbased_fromfile authenticates using host-based authentication.
pub fn (s &Session) auth_hostbased_fromfile(username string, hostname string, host_username string, pubkey string, privkey string, passphrase string) ! {
	rc := C.libssh2_userauth_hostbased_fromfile(s.handle, &char(username.str), &char(hostname.str),
		&char(host_username.str), &char(pubkey.str), &char(privkey.str), &char(passphrase.str))
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
struct C.LIBSSH2_USERAUTH_KBD_INT_PROMPT {
	text   &char
	length u32
	echo   u8
}

@[typedef]
struct C.LIBSSH2_USERAUTH_KBD_INT_RESPONSE {
	text   &char
	length u32
}

// auth_keyboard_interactive authenticates using keyboard-interactive method.
// The callback is invoked when the server sends a challenge.
// The callback receives prompt questions and echo flags, and should return responses.
pub fn (s &Session) auth_keyboard_interactive(username string, callback fn (questions []string, echoes []bool) []string) ! {
	// V callback adapter for the C callback
	my_cb := fn [callback] (session &C.LIBSSH2_SESSION, name &&char, instruction &&char,
		num_prompts i32, prompts &C.LIBSSH2_USERAUTH_KBD_INT_PROMPT,
		responses &C.LIBSSH2_USERAUTH_KBD_INT_RESPONSE, abstract voidptr) {
		if num_prompts <= 0 {
			return
		}

		mut questions := []string{}
		mut echoes := []bool{}
		for i := 0; i < num_prompts; i++ {
			unsafe {
				questions << cstring_to_vstring(prompts[i].text)
				echoes << (prompts[i].echo != 0)
			}
		}

		answers := callback(questions, echoes)

		for i := 0; i < num_prompts && i < answers.len; i++ {
			unsafe {
				responses[i].text = &char(answers[i].str)
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
	ptr := C.libssh2_userauth_list(s.handle, &char(username.str), username.len)
	if unsafe { ptr == nil } {
		return ssh2_error(-1, s)
	}
	methods_str := unsafe { cstring_to_vstring(ptr) }
	return parse_auth_methods(methods_str)
}

// is_authenticated returns true if the session has been successfully authenticated.
pub fn (s &Session) is_authenticated() bool {
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
