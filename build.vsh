#!/usr/bin/env -S v run
// build.vsh — Build, test, and maintain the ssh2 V module
//
// Usage:
//   v run build.vsh              # runs the default task (check)
//   v run build.vsh help         # list all tasks
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

const project_name = 'ssh2'

// ── Helpers ────────────────────────────────────────────────────────────

fn check_docker() ! {
	result := os.execute('docker --version 2>/dev/null')
	if result.exit_code != 0 {
		return error('Docker is not installed. Install it from https://docker.com')
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
	run: fn (t build.Task) ! {
		result := os.execute('v run setup.vsh')
		if result.exit_code != 0 {
			return error('setup failed')
		}
	}
)

// build — compile the project
ctx.task(
	name: 'build'
	help: 'Compile the project'
	depends: ['fmt.check']
	run: fn (t build.Task) ! {
		result := os.execute('v .')
		if result.exit_code != 0 {
			return error('build failed')
		}
		println('build: OK')
	}
)

// build.prod — production build
ctx.task(
	name: 'build.prod'
	help: 'Compile in production mode'
	depends: ['fmt.check']
	run: fn (t build.Task) ! {
		result := os.execute('v -prod -o ${project_name} .')
		if result.exit_code != 0 {
			return error('production build failed')
		}
		println('build.prod: OK -> ./${project_name}')
	}
)

// test — run unit tests
ctx.task(
	name: 'test'
	help: 'Run unit tests (no server required)'
	depends: ['fmt.check']
	run: fn (t build.Task) ! {
		result := os.execute('v test .')
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
	run: fn (t build.Task) ! {
		host := os.getenv('SSH2_TEST_HOST')
		if host == '' {
			println('Skipping integration tests — set SSH2_TEST_HOST, SSH2_TEST_USER, SSH2_TEST_PASS')
			return
		}
		result := os.execute('v test .')
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
	run: fn (t build.Task) ! {
		result := os.execute('v fmt -w .')
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
	run: fn (t build.Task) ! {
		result := os.execute('v fmt -check . 2>&1')
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
	run: fn (t build.Task) ! {
		artifacts := ['ssh2', project_name, 'bin/', 'modules/']
		for a in artifacts {
			if os.exists(a) {
				os.rm(a) or { continue }
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
	run: fn (t build.Task) ! {
		// handled before ctx.run() to avoid build module prefix
	}
)

// doc — show project documentation
ctx.task(
	name: 'doc'
	help: 'Show module documentation'
	run: fn (t build.Task) ! {
		println('── Project: ${project_name} ──────────────────────────────')
		println('')
		result := os.execute('v doc . 2>&1')
		print(result.output)
	}
)

// check — full validation (fmt + build + test)
ctx.task(
	name: 'check'
	help: 'Run full validation: fmt → build → test'
	depends: ['build', 'test']
	run: fn (t build.Task) ! {
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
	run: fn (t build.Task) ! {
		check_docker()!

		// Check if already running
		existing := os.execute('docker ps -q --filter name=vssh2-test 2>/dev/null')
		if existing.output.trim_space() != '' {
			println('docker.up: container vssh2-test is already running')
			return
		}

		// Start an Ubuntu container with SSH
		println('docker.up: pulling ubuntu:latest...')
		_ := os.execute('docker pull ubuntu:latest -q')

		println('docker.up: starting container...')
		result := os.execute('docker run -d --name vssh2-test -p 2222:22 ubuntu:latest sh -c "'
			+ 'apt-get update -qq && apt-get install -y -qq openssh-server && '
			+ "echo 'root:test' | chpasswd && "
			+ "sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && "
			+ 'service ssh start && sleep infinity" 2>&1')

		if result.exit_code != 0 {
			return error('docker.up: failed to start container:\n${result.output}')
		}

		// Wait for SSH to be ready
		println('docker.up: waiting for SSH...')
		for _ in 0..30 {
			ready := os.execute('docker exec vssh2-test sh -c "service ssh status 2>/dev/null"')
			if ready.exit_code == 0 {
				_ := os.execute('docker inspect -f "{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}" vssh2-test 2>/dev/null')
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
	run: fn (t build.Task) ! {
		check_docker()!
		existing := os.execute('docker ps -aq --filter name=vssh2-test 2>/dev/null')
		if existing.output.trim_space() == '' {
			println('docker.down: no container to remove')
			return
		}
		os.execute('docker rm -f vssh2-test 2>/dev/null')
		println('docker.down: container removed')
	}
)

// docker.shell — get an interactive shell in the test container
ctx.task(
	name: 'docker.shell'
	help: 'Get an interactive shell in the test container'
	run: fn (t build.Task) ! {
		check_docker()!
		existing := os.execute('docker ps -q --filter name=vssh2-test 2>/dev/null')
		if existing.output.trim_space() == '' {
			return error('docker.shell: container vssh2-test is not running. Run v run build.vsh docker.up first')
		}
		println('docker.shell: opening shell...')
		os.system('docker exec -it vssh2-test bash')
	}
)

// docker.test — run integration tests against the test container
ctx.task(
	name: 'docker.test'
	help: 'Start container, run integration tests, then clean up'
	run: fn (t build.Task) ! {
		check_docker()!

		// Start container if not already running
		existing := os.execute('docker ps -q --filter name=vssh2-test 2>/dev/null')
		if existing.output.trim_space() == '' {
			println('docker.test: starting container...')
			result := os.execute('v run build.vsh docker.up 2>&1')
			if result.exit_code != 0 {
				return error('docker.test: failed to start container:\n${result.output}')
			}
			// Will be stopped at the end
		}

		// Run integration tests
		println('docker.test: running integration tests...')
		env := 'SSH2_TEST_HOST=localhost SSH2_TEST_PORT=2222 SSH2_TEST_USER=root SSH2_TEST_PASS=test'
		test_result := os.execute('${env} v test .')
		if test_result.exit_code != 0 {
			println('docker.test: tests FAILED')
			// Keep container alive for debugging
			println('  Container kept running for debugging: v run build.vsh docker.shell')
			println('  Clean up: v run build.vsh docker.down')
			return error('integration tests failed')
		}
		println('docker.test: all integration tests PASSED')

		// Clean up
		os.execute('docker rm -f vssh2-test 2>/dev/null')
		println('docker.test: container removed')
	}
)

// release — full release pipeline
ctx.task(
	name: 'release'
	help: 'Bump version, run checks, build, and print tag instructions. Set RELEASE_BUMP=major|minor|patch (default: patch)'
	run: fn (t build.Task) ! {
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
		result := os.execute('v run build.vsh check')
		if result.exit_code != 0 {
			// Revert version bump on failure
			manifest.version = v.str()
			os.write_file('v.mod', vmod.encode(manifest))!
			return error('release: checks failed, version reverted')
		}
		// Production build
		result2 := os.execute('v -prod -o ${project_name} .')
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
	result := os.execute('v run build.vsh --tasks 2>&1')
	println('── ${project_name} — available tasks ────────────────────')
	println('')
	print(result.output)
	println('')
	println('Usage: v run build.vsh <task>')
	return
}

ctx.run()
