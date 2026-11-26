module main

import net.http
import os
import time

fn run_check(check CheckConfig) CheckResult {
	started := time.now()
	observed := match check.kind {
		'http' {
			check_http(check)
		}
		'command' {
			check_command(check, check.target, check.args)
		}
		'git_remote' {
			check_git_remote(check)
		}
		'file' {
			check_file(check)
		}
		'env' {
			check_env(check)
		}
		'tcp' {
			check_tcp(check)
		}
		'dns' {
			check_dns(check)
		}
		'diff' {
			check_diff(check)
		}
		else {
			Outcome{
				code:    'unsupported_check'
				message: 'unsupported check kind'
				passed:  false
			}
		}
	}

	outcome := apply_expectation(check.kind, check.expect, observed)
	duration := time.since(started).milliseconds()
	status := if outcome.passed {
		'pass'
	} else if check.critical {
		'fail'
	} else {
		'warn'
	}
	return CheckResult{
		name:        check.name
		kind:        check.kind
		target:      safe_target(check.kind, check.target)
		expect:      check.expect
		status:      status
		code:        outcome.code
		message:     outcome.message
		duration_ms: duration
		critical:    check.critical
	}
}

// apply_expectation turns a check into a denial assertion when expect is
// "fail", so a config can prove that a sandbox blocks access. Only failures
// that show the access was denied count; a broken probe is inconclusive.
fn apply_expectation(kind string, expect string, observed Outcome) Outcome {
	if expect != 'fail' {
		return observed
	}
	if observed.passed || (kind == 'http' && observed.code == 'unexpected_http_status') {
		return Outcome{
			code:    'unexpectedly_allowed'
			message: 'expected access to be denied but it was allowed: ${observed.message}'
		}
	}
	if observed.code !in denial_codes(kind) {
		return Outcome{
			code:    'inconclusive_denial'
			message: 'could not verify denial: ${observed.code}: ${observed.message}'
		}
	}
	return Outcome{
		passed:  true
		code:    'blocked_as_expected'
		message: 'failed as expected: ${observed.code}'
	}
}

// denial_codes lists the failure codes that show access was denied for each
// check kind. Any HTTP response means the endpoint was reachable, and a Git
// remote check only proves denial if Git itself ran.
fn denial_codes(kind string) []string {
	return match kind {
		'http' {
			['http_request_failed']
		}
		'command' {
			['executable_not_found', 'command_failed', 'command_timeout']
		}
		'git_remote' {
			['command_failed', 'command_timeout']
		}
		'file' {
			['file_not_found', 'file_not_readable']
		}
		'tcp' {
			['dns_resolution_failed', 'tcp_connect_refused', 'tcp_connect_timeout',
				'tcp_connect_failed']
		}
		'dns' {
			['dns_resolution_failed']
		}
		else {
			[]string{}
		}
	}
}

struct Outcome {
	passed  bool
	code    string
	message string
}

fn check_git_remote(check CheckConfig) Outcome {
	mut args := ['ls-remote', '--exit-code', check.target]
	args << check.args
	return check_command(check, 'git', args)
}

fn check_http(check CheckConfig) Outcome {
	response := http.fetch(
		url:                  check.target
		method:               .get
		read_timeout:         i64(check.timeout_ms) * time.millisecond
		write_timeout:        i64(check.timeout_ms) * time.millisecond
		max_retries:          1
		stop_receiving_limit: 2_048
	) or { return Outcome{
		code:    'http_request_failed'
		message: err.msg()
	} }
	if response.status_code != check.expect_status {
		return Outcome{
			code:    'unexpected_http_status'
			message: 'expected ${check.expect_status}, received ${response.status_code}'
		}
	}
	return Outcome{
		passed:  true
		code:    'ok'
		message: 'HTTP ${response.status_code}'
	}
}

fn check_command(check CheckConfig, executable string, args []string) Outcome {
	executable_path := os.find_abs_path_of_executable(executable) or {
		return Outcome{
			code:    'executable_not_found'
			message: 'executable "${executable}" was not found'
		}
	}
	mut process := os.new_process(executable_path)
	process.set_args(args)
	process.use_pgroup = true
	if check.working_directory != '' {
		if !os.is_dir(check.working_directory) {
			return Outcome{
				code:    'working_directory_not_found'
				message: 'working directory does not exist'
			}
		}
		process.set_work_folder(check.working_directory)
	}
	process.set_redirect_stdio()
	process.run()
	started := time.now()
	for process.is_alive() {
		if process.is_pending(.stdout) {
			process.stdout_read()
		}
		if process.is_pending(.stderr) {
			process.stderr_read()
		}
		if time.since(started).milliseconds() >= check.timeout_ms {
			process.signal_pgkill()
			process.wait()
			process.close()
			return Outcome{
				code:    'command_timeout'
				message: 'timed out after ${check.timeout_ms} ms'
			}
		}
		time.sleep(10 * time.millisecond)
	}
	process.wait()
	if process.is_pending(.stdout) {
		process.stdout_read()
	}
	if process.is_pending(.stderr) {
		process.stderr_read()
	}
	exit_code := process.code
	process.close()
	if exit_code != 0 {
		return Outcome{
			code:    'command_failed'
			message: 'exit code ${exit_code}'
		}
	}
	return Outcome{
		passed:  true
		code:    'ok'
		message: 'exit code 0'
	}
}

fn check_file(check CheckConfig) Outcome {
	if !os.exists(check.target) {
		return Outcome{
			code:    'file_not_found'
			message: 'path does not exist'
		}
	}
	if !os.is_readable(check.target) {
		return Outcome{
			code:    'file_not_readable'
			message: 'path is not readable'
		}
	}
	return Outcome{
		passed:  true
		code:    'ok'
		message: if os.is_dir(check.target) { 'directory is readable' } else { 'file is readable' }
	}
}

fn check_env(check CheckConfig) Outcome {
	if os.getenv(check.target).trim_space() == '' {
		return Outcome{
			code:    'env_not_set'
			message: 'environment variable is not set'
		}
	}
	return Outcome{
		passed:  true
		code:    'ok'
		message: 'environment variable is set'
	}
}

fn safe_target(kind string, target string) string {
	if kind !in ['http', 'git_remote'] {
		return target
	}
	mut clean := target.all_before('?')
	if scheme_index := clean.index('://') {
		prefix := clean[..scheme_index + 3]
		remainder := clean[scheme_index + 3..]
		host_end := remainder.index('/') or { remainder.len }
		authority := remainder[..host_end]
		if at_index := authority.last_index('@') {
			clean = prefix + authority[at_index + 1..] + remainder[host_end..]
		}
	}
	return clean
}

fn build_report(results []CheckResult) Report {
	mut passed := 0
	mut warned := 0
	mut failed := 0
	mut skipped := 0
	mut skipped_critical := false
	for result in results {
		match result.status {
			'pass' {
				passed++
			}
			'warn' {
				warned++
			}
			'fail' {
				failed++
			}
			'skipped' {
				skipped++
				skipped_critical = skipped_critical || result.critical
			}
			else {}
		}
	}
	return Report{
		status:  if failed > 0 || skipped_critical {
			'fail'
		} else if warned > 0 || skipped > 0 {
			'warn'
		} else {
			'pass'
		}
		checks:  results
		summary: Summary{
			total:   results.len
			passed:  passed
			warned:  warned
			failed:  failed
			skipped: skipped
		}
	}
}
