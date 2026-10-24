#!/usr/bin/env -S v run

// build.vsh — Build, test, and maintain the vssh2 V module
//
// Usage:
//   v run build.vsh              # runs the default task (check)
//   v run build.vsh help         # list all tasks
//   v run build.vsh setup        # install libssh2 system dependency
//   v run build.vsh build        # compile
//   v run build.vsh test         # run tests
//   v run build.vsh fmt          # format source files
//   v run build.vsh clean        # remove build artifacts
//   v run build.vsh release      # full release pipeline
//   v run build.vsh docker.up    # start SSH test container
//   v run build.vsh docker.shell # shell into test container
//   v run build.vsh docker.test  # run integration tests in container
//   v run build.vsh docker.down  # stop test container

import build
import os
import time
import v.vmod
import semver

const project_name = 'vssh2'

const color_green = '\x1b[32m'
const color_yellow = '\x1b[33m'
const color_red = '\x1b[31m'
const color_reset = '\x1b[0m'

// ── Helpers ────────────────────────────────────────────────────────────

fn check_docker() ! {
	result := os.exec(['docker', '--version'])
	if result.exit_code != 0 {
		return error('Docker is not installed. Install it from https://docker.com')
	}
}

fn info(msg string) {
	println('${color_green}[vssh2]${color_reset} ${msg}')
}

fn warn(msg string) {
	println('${color_yellow}[vssh2]${color_reset} ${msg}')
}

fn print_error(msg string) {
	println('${color_red}[vssh2]${color_reset} ${msg}')
}

fn command_exists(cmd string) bool {
	res := os.exec(['which', cmd])
	return res.exit_code == 0 && res.output.trim_space() != ''
}

fn have_pkg_config() bool {
	return command_exists('pkg-config')
}

// module_search_path keeps the default V module roots and adds the directory
// that contains this repository, so `examples/main.v` can `import vssh2` from a
// plain clone (without `v install` or a ~/.vmodules symlink).
fn module_search_path() string {
	return '@vlib|@vmodules|' + os.dir(os.getwd())
}

fn libssh2_found() bool {
	// Check via pkg-config first
	if have_pkg_config() {
		res := os.exec(['pkg-config', '--exists', 'libssh2'])
		if res.exit_code == 0 {
			return true
		}
	}

	// Directories to search — start with local/project paths, then system paths
	cwd := os.getenv('PWD')

	mut lib_paths := []string{}
	// Current working directory (where `v run build.vsh setup` was invoked)
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

// run_setup — install libssh2 via the system package manager
fn run_setup() ! {
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
			os.system_args(['brew', 'install', 'libssh2'])
		} else {
			return error('Homebrew not found. Install it from https://brew.sh')
		}
	} else if platform == 'Linux' {
		// Linux
		if command_exists('apt-get') {
			info('Installing libssh2 via apt...')
			os.system_args(['sudo', 'apt-get', 'update', '-qq'])
			os.system_args(['sudo', 'apt-get', 'install', '-y', '-qq', 'libssh2-1-dev'])
		} else if command_exists('dnf') {
			info('Installing libssh2 via dnf...')
			os.system_args(['sudo', 'dnf', 'install', '-y', 'libssh2-devel'])
		} else if command_exists('yum') {
			info('Installing libssh2 via yum...')
			os.system_args(['sudo', 'yum', 'install', '-y', 'libssh2-devel'])
		} else if command_exists('pacman') {
			info('Installing libssh2 via pacman...')
			os.system_args(['sudo', 'pacman', '-S', '--noconfirm', 'libssh2'])
		} else if command_exists('apk') {
			info('Installing libssh2 via apk...')
			os.system_args(['sudo', 'apk', 'add', 'libssh2-dev'])
		} else if command_exists('zypper') {
			info('Installing libssh2 via zypper...')
			os.system_args(['sudo', 'zypper', 'install', '-y', 'libssh2-devel'])
		} else {
			print_error('Could not detect your package manager.')
			print_error('')
			print_error('Please install libssh2 manually:')
			print_error('  Debian/Ubuntu:  sudo apt-get install libssh2-1-dev')
			print_error('  Fedora:         sudo dnf install libssh2-devel')
			print_error('  Arch:           sudo pacman -S libssh2')
			print_error('  Alpine:         sudo apk add libssh2-dev')
			print_error('  openSUSE:       sudo zypper install libssh2-devel')
			return error('Could not detect your package manager.')
		}
	} else {
		return error('Unsupported platform: ${platform}\nPlease install libssh2 manually (see README.md).')
	}

	// Verify installation
	if libssh2_found() {
		info('libssh2 installed successfully.')
	} else {
		warn('libssh2 may have been installed, but pkg-config cannot find it.')
		warn('You may need to add it to PKG_CONFIG_PATH, e.g.:')
		warn('  export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:\$PKG_CONFIG_PATH"')
		return error('libssh2 may have been installed, but pkg-config cannot find it.')
	}
}

// ── Context ──────────────────────────────────────────────────────────
mut ctx := build.context(
	default: 'check'
)

// ── Tasks ─────────────────────────────────────────────────────────────

// setup — install libssh2 system dependency
ctx.task(
	name: 'setup'
	help: 'Install libssh2 via the system package manager'
	run:  fn (t build.Task) ! {
		run_setup()!
	}
)

// build — compile the project
ctx.task(
	name:    'build'
	help:    'Compile the project'
	depends: ['fmt.check']
	run:     fn (t build.Task) ! {
		// Compile only (not `v examples/main.v`, which would also run it) into
		// the gitignored bin/ directory.
		os.mkdir_all('bin') or {}
		result := os.exec(['v', '-path', module_search_path(), '-o', 'bin/vssh2-example',
			'examples/main.v'])
		if result.exit_code != 0 {
			return error('build failed')
		}
		println('build: OK')
	}
)

// build.prod — production build
ctx.task(
	name:    'build.prod'
	help:    'Compile in production mode'
	depends: ['fmt.check']
	run:     fn (t build.Task) ! {
		result := os.exec(['v', '-path', module_search_path(), '-prod', '-o', project_name,
			'examples/main.v'])
		if result.exit_code != 0 {
			return error('production build failed')
		}
		println('build.prod: OK -> ./${project_name}')
	}
)

// test — run unit tests
ctx.task(
	name:    'test'
	help:    'Run unit tests (no server required)'
	depends: ['fmt.check']
	run:     fn (t build.Task) ! {
		// The tests live next to the module (`vssh2_test.v`), not in examples/.
		result := os.exec(['v', 'test', '.'])
		if result.exit_code != 0 {
			return error('tests failed')
		}
		println('test: OK')
	}
)

// test.integration — run integration tests (requires SSH server)
ctx.task(
	name: 'test.integration'
	help: 'Run integration tests (set SSH2_TEST_HOST, SSH2_TEST_USER, SSH2_TEST_PASS)'
	run:  fn (t build.Task) ! {
		host := os.getenv('SSH2_TEST_HOST')
		if host == '' {
			println('Skipping integration tests — set SSH2_TEST_HOST, SSH2_TEST_USER, SSH2_TEST_PASS')
			return
		}
		result := os.exec(['v', 'test', '.'])
		if result.exit_code != 0 {
			return error('integration tests failed')
		}
		println('test.integration: OK')
	}
)

// fmt — format all V source files
ctx.task(
	name: 'fmt'
	help: 'Format all V source files'
	run:  fn (t build.Task) ! {
		result := os.exec(['v', 'fmt', '-w', '.'])
		if result.exit_code != 0 {
			return error('formatting failed')
		}
		println('fmt: OK')
	}
)

// fmt.check — verify formatting without modifying (runs before build/test)
ctx.task(
	name: 'fmt.check'
	help: 'Check formatting (no changes made)'
	run:  fn (t build.Task) ! {
		result := os.exec(['v', 'fmt', '-check', '.'])
		if result.exit_code != 0 {
			println('Some files need formatting. Run: v run build.vsh fmt')
			return error('fmt.check failed')
		}
	}
)

// clean — remove build artifacts
ctx.task(
	name: 'clean'
	help: 'Remove build artifacts'
	run:  fn (t build.Task) ! {
		artifacts := ['bin', project_name, 'build']
		for a in artifacts {
			if os.exists(a) {
				os.rmdir_all(a) or { os.rm(a) or { continue } }
				println('  removed: ${a}')
			}
		}
		println('clean: OK')
	}
)

// help — list all available tasks with descriptions
ctx.task(
	name: 'help'
	help: 'List all available tasks'
	run:  fn (t build.Task) ! {
		// handled before ctx.run() to avoid build module prefix
	}
)

// doc — show project documentation
ctx.task(
	name: 'doc'
	help: 'Show module documentation'
	run:  fn (t build.Task) ! {
		println('── Project: ${project_name} ──────────────────────────────')
		println('')
		result := os.exec(['v', 'doc', '.'])
		print(result.output)
	}
)

// check — full validation (fmt + build + test)
ctx.task(
	name:    'check'
	help:    'Run full validation: fmt → build → test'
	depends: ['build', 'test']
	run:     fn (t build.Task) ! {
		println('check: all passed ✓')
	}
)

// ── Docker tasks ───────────────────────────────────────────────────────
// These tasks manage a test container with SSH for integration testing.
// They require Docker to be installed on the host.

// docker.up — start a test container with SSH
ctx.task(
	name: 'docker.up'
	help: 'Start a test container with SSH for integration testing'
	run:  fn (t build.Task) ! {
		check_docker()!

		// Check if already running
		existing := os.exec(['docker', 'ps', '-q', '--filter', 'name=vssh2-test'])
		if existing.output.trim_space() != '' {
			println('docker.up: container vssh2-test is already running')
			return
		}

		// Start an Ubuntu container with SSH
		println('docker.up: pulling ubuntu:latest...')
		_ := os.exec(['docker', 'pull', 'ubuntu:latest', '-q'])

		println('docker.up: starting container...')
		setup_script := 'apt-get update -qq && apt-get install -y -qq openssh-server && ' +
			"echo 'root:test' | chpasswd && " +
			"sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && " +
			'service ssh start && sleep infinity'
		result := os.exec(['docker', 'run', '-d', '--name', 'vssh2-test', '-p', '2222:22',
			'ubuntu:latest', 'sh', '-c', setup_script])

		if result.exit_code != 0 {
			return error('docker.up: failed to start container:\n${result.output}')
		}

		// Wait for SSH to be ready
		println('docker.up: waiting for SSH...')
		for _ in 0 .. 30 {
			ready := os.exec(['docker', 'exec', 'vssh2-test', 'sh', '-c', 'service ssh status'])
			if ready.exit_code == 0 {
				_ := os.exec(['docker', 'inspect', '-f',
					'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}', 'vssh2-test'])
				println('docker.up: ready — SSH available at localhost:2222')
				println('')
				println('  Run integration tests:')
				println('    SSH2_TEST_HOST=localhost SSH2_TEST_PORT=2222 SSH2_TEST_USER=root SSH2_TEST_PASS=test v run build.vsh test.integration')
				println('')
				println('  Or get a shell:')
				println('    v run build.vsh docker.shell')
				return
			}
			time.sleep(2)
		}
		return error('docker.up: SSH did not start in time')
	}
)

// docker.down — stop and remove the test container
ctx.task(
	name: 'docker.down'
	help: 'Stop and remove the test container'
	run:  fn (t build.Task) ! {
		check_docker()!
		existing := os.exec(['docker', 'ps', '-aq', '--filter', 'name=vssh2-test'])
		if existing.output.trim_space() == '' {
			println('docker.down: no container to remove')
			return
		}
		os.exec(['docker', 'rm', '-f', 'vssh2-test'])
		println('docker.down: container removed')
	}
)

// docker.shell — get an interactive shell in the test container
ctx.task(
	name: 'docker.shell'
	help: 'Get an interactive shell in the test container'
	run:  fn (t build.Task) ! {
		check_docker()!
		existing := os.exec(['docker', 'ps', '-q', '--filter', 'name=vssh2-test'])
		if existing.output.trim_space() == '' {
			return error('docker.shell: container vssh2-test is not running. Run v run build.vsh docker.up first')
		}
		println('docker.shell: opening shell...')
		os.system_args(['docker', 'exec', '-it', 'vssh2-test', 'bash'])
	}
)

// docker.test — run integration tests against the test container
ctx.task(
	name: 'docker.test'
	help: 'Start container, run integration tests, then clean up'
	run:  fn (t build.Task) ! {
		check_docker()!

		// Start container if not already running
		existing := os.exec(['docker', 'ps', '-q', '--filter', 'name=vssh2-test'])
		if existing.output.trim_space() == '' {
			println('docker.test: starting container...')
			result := os.exec(['v', 'run', 'build.vsh', 'docker.up'])
			if result.exit_code != 0 {
				return error('docker.test: failed to start container:\n${result.output}')
			}
			// Will be stopped at the end
		}

		// Run integration tests
		println('docker.test: running integration tests...')
		test_result := os.exec(['env', 'SSH2_TEST_HOST=localhost', 'SSH2_TEST_PORT=2222',
			'SSH2_TEST_USER=root', 'SSH2_TEST_PASS=test', 'v', 'test', '.'])
		if test_result.exit_code != 0 {
			println('docker.test: tests FAILED')
			// Keep container alive for debugging
			println('  Container kept running for debugging: v run build.vsh docker.shell')
			println('  Clean up: v run build.vsh docker.down')
			return error('integration tests failed')
		}
		println('docker.test: all integration tests PASSED')

		// Clean up
		os.exec(['docker', 'rm', '-f', 'vssh2-test'])
		println('docker.test: container removed')
	}
)

// release — full release pipeline
ctx.task(
	name: 'release'
	help: 'Bump version, run checks, build, and print tag instructions. Set RELEASE_BUMP=major|minor|patch (default: patch)'
	run:  fn (t build.Task) ! {
		// Determine bump type from env (default: patch)
		bump_type := match os.getenv('RELEASE_BUMP') {
			'major' { semver.Increment.major }
			'minor' { semver.Increment.minor }
			else { semver.Increment.patch }
		}

		// Read current version from v.mod
		mut manifest := vmod.from_file('v.mod')!
		v := semver.from(manifest.version)!
		new_v := v.increment(bump_type)

		println('release: ${manifest.version} → ${new_v}')

		// Update v.mod
		manifest.version = new_v.str()
		os.write_file('v.mod', vmod.encode(manifest))!

		println('')
		println('Running validation...')
		// Run full check via subprocess (fmt → build → test)
		result := os.exec(['v', 'run', 'build.vsh', 'check'])
		if result.exit_code != 0 {
			// Revert version bump on failure
			manifest.version = v.str()
			os.write_file('v.mod', vmod.encode(manifest))!
			return error('release: checks failed, version reverted')
		}
		// Production build
		result2 := os.exec(['v', '-path', module_search_path(), '-prod', '-o', project_name,
			'examples/main.v'])
		if result2.exit_code != 0 {
			manifest.version = v.str()
			os.write_file('v.mod', vmod.encode(manifest))!
			return error('release: production build failed, version reverted')
		}

		println('')
		println('release: v${new_v} ready ✓')
		println('')
		println('Next steps:')
		println('  git add v.mod')
		println('  git commit -m "chore: bump version to v${new_v}"')
		println('  git tag v${new_v}')
		println('  git push origin v${new_v}')
	}
)

// ── Run ───────────────────────────────────────────────────────────────
// Handle special flags before ctx.run() to avoid build module side effects

if 'help' in os.args {
	result := os.exec(['v', 'run', 'build.vsh', '--tasks'])
	println('── ${project_name} — available tasks ────────────────────')
	println('')
	print(result.output)
	println('')
	println('Usage: v run build.vsh <task>')
	return
}

ctx.run()
