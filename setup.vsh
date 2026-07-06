#!/usr/bin/env -S v run
// setup.vsh — Install libssh2 for the ssh2 V module
//
// Usage:  v run setup.vsh
//
// Detects your OS and installs libssh2 if missing.

import os

const color_green = '\x1b[32m'
const color_yellow = '\x1b[33m'
const color_red = '\x1b[31m'
const color_reset = '\x1b[0m'

fn info(msg string) {
	println('${color_green}[ssh2]${color_reset} ${msg}')
}

fn warn(msg string) {
	println('${color_yellow}[ssh2]${color_reset} ${msg}')
}

fn print_error(msg string) {
	println('${color_red}[ssh2]${color_reset} ${msg}')
}

fn command_exists(cmd string) bool {
	res := os.execute('which ${cmd} 2>/dev/null')
	return res.exit_code == 0 && res.output.trim_space() != ''
}

fn have_pkg_config() bool {
	return command_exists('pkg-config')
}

fn libssh2_found() bool {
	// Check via pkg-config first
	if have_pkg_config() {
		res := os.execute('pkg-config --exists libssh2 2>/dev/null')
		if res.exit_code == 0 {
			return true
		}
	}

	// Directories to search — start with local/project paths, then system paths
	cwd := os.getenv('PWD')

	mut lib_paths := []string{}
	// Current working directory (where `v run setup.vsh` was invoked)
	lib_paths << cwd
	lib_paths << os.join_path(cwd, 'lib')
	lib_paths << os.join_path(cwd, '.lib')
	lib_paths << os.join_path(cwd, 'vendor')
	lib_paths << os.join_path(cwd, 'deps')
	lib_paths << os.join_path(cwd, '.deps')
	// Parent directories (in case run from a subdirectory)
	lib_paths << os.join_path(cwd, '..')
	lib_paths << os.join_path(cwd, '../lib')
	lib_paths << os.join_path(cwd, '../vendor')
	// Standard system paths
	lib_paths << '/usr/lib'
	lib_paths << '/usr/local/lib'
	lib_paths << '/opt/homebrew/lib'
	lib_paths << '/usr/lib64'
	lib_paths << '/usr/lib/x86_64-linux-gnu'
	lib_paths << '/usr/lib/aarch64-linux-gnu'

	for dir in lib_paths {
		if os.exists(dir) {
			for lib in ['libssh2.so', 'libssh2.dylib', 'libssh2.a'] {
				if os.exists(os.join_path(dir, lib)) {
					return true
				}
			}
		}
	}
	return false
}

fn main() {
	if libssh2_found() {
		info('libssh2 is already installed.')
		return
	}

	platform := os.uname().sysname
	info('Detected platform: ${platform}')

	if platform == 'Darwin' {
		// macOS
		if command_exists('brew') {
			info('Installing libssh2 via Homebrew...')
			os.system('brew install libssh2')
		} else {
			print_error('Homebrew not found. Install it from https://brew.sh')
			exit(1)
		}
	} else if platform == 'Linux' {
		// Linux
		if command_exists('apt-get') {
			info('Installing libssh2 via apt...')
			os.system('sudo apt-get update -qq')
			os.system('sudo apt-get install -y -qq libssh2-1-dev')
		} else if command_exists('dnf') {
			info('Installing libssh2 via dnf...')
			os.system('sudo dnf install -y libssh2-devel')
		} else if command_exists('yum') {
			info('Installing libssh2 via yum...')
			os.system('sudo yum install -y libssh2-devel')
		} else if command_exists('pacman') {
			info('Installing libssh2 via pacman...')
			os.system('sudo pacman -S --noconfirm libssh2')
		} else if command_exists('apk') {
			info('Installing libssh2 via apk...')
			os.system('sudo apk add libssh2-dev')
		} else if command_exists('zypper') {
			info('Installing libssh2 via zypper...')
			os.system('sudo zypper install -y libssh2-devel')
		} else {
			print_error('Could not detect your package manager.')
			print_error('')
			print_error('Please install libssh2 manually:')
			print_error('  Debian/Ubuntu:  sudo apt-get install libssh2-1-dev')
			print_error('  Fedora:         sudo dnf install libssh2-devel')
			print_error('  Arch:           sudo pacman -S libssh2')
			print_error('  Alpine:         sudo apk add libssh2-dev')
			print_error('  openSUSE:       sudo zypper install libssh2-devel')
			exit(1)
		}
	} else {
		print_error('Unsupported platform: ${platform}')
		print_error('Please install libssh2 manually (see README.md).')
		exit(1)
	}

	// Verify installation
	if libssh2_found() {
		info('libssh2 installed successfully.')
	} else {
		warn('libssh2 may have been installed, but pkg-config cannot find it.')
		warn('You may need to add it to PKG_CONFIG_PATH, e.g.:')
		warn("  export PKG_CONFIG_PATH=\"/opt/homebrew/lib/pkgconfig:\$PKG_CONFIG_PATH\"")
		exit(1)
	}
}
