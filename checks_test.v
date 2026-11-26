module main

import net.http

fn test_validate_config_accepts_supported_checks() {
	config := Config{
		checks: [
			CheckConfig{
				name:   'Git'
				kind:   'command'
				target: 'git'
			},
		]
	}
	validate_config(config) or { assert false, err.msg() }
}

fn test_validate_config_rejects_unknown_kind() {
	config := Config{
		checks: [
			CheckConfig{
				name:   'Unknown'
				kind:   'magic'
				target: 'somewhere'
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	} else {
		assert err.msg().contains('unsupported kind')
	}
}

fn test_build_report_tracks_warning_and_failure() {
	report := build_report([
		CheckResult{
			status: 'pass'
		},
		CheckResult{
			status: 'warn'
		},
		CheckResult{
			status: 'fail'
		},
	])
	assert report.status == 'fail'
	assert report.summary.total == 3
	assert report.summary.passed == 1
	assert report.summary.warned == 1
	assert report.summary.failed == 1
}

fn test_safe_target_removes_credentials_and_query() {
	target := safe_target('http', 'https://user:secret@example.com/health?token=secret')
	assert target == 'https://example.com/health'
}

fn test_expect_fail_passes_when_check_fails() {
	outcome := apply_expectation('file', 'fail', Outcome{
		code:    'file_not_found'
		message: 'path does not exist'
	})
	assert outcome.passed
	assert outcome.code == 'blocked_as_expected'
	assert outcome.message.contains('file_not_found')
}

fn test_expect_fail_fails_when_check_passes() {
	outcome := apply_expectation('file', 'fail', Outcome{
		passed:  true
		code:    'ok'
		message: 'file is readable'
	})
	assert !outcome.passed
	assert outcome.code == 'unexpectedly_allowed'
}

fn test_expect_pass_keeps_outcome() {
	observed := Outcome{
		code:    'file_not_found'
		message: 'path does not exist'
	}
	assert apply_expectation('file', 'pass', observed) == observed
}

fn test_validate_config_rejects_unknown_expectation() {
	config := Config{
		checks: [
			CheckConfig{
				name:   'Git'
				kind:   'command'
				target: 'git'
				expect: 'maybe'
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	} else {
		assert err.msg().contains('expect must be')
	}
}

fn test_run_check_expect_fail_on_missing_file() {
	result := run_check(CheckConfig{
		name:       'Host SSH keys'
		kind:       'file'
		target:     '/definitely/not/here/.ssh'
		expect:     'fail'
		timeout_ms: 100
	})
	assert result.status == 'pass'
	assert result.expect == 'fail'
	assert result.code == 'blocked_as_expected'
}

fn test_expect_fail_treats_any_http_response_as_allowed() {
	outcome := apply_expectation('http', 'fail', Outcome{
		code:    'unexpected_http_status'
		message: 'expected 200, received 404'
	})
	assert !outcome.passed
	assert outcome.code == 'unexpectedly_allowed'
}

fn test_expect_fail_passes_when_http_request_fails() {
	outcome := apply_expectation('http', 'fail', Outcome{
		code:    'http_request_failed'
		message: 'connection refused'
	})
	assert outcome.passed
	assert outcome.code == 'blocked_as_expected'
}

fn test_expect_fail_git_remote_without_git_is_inconclusive() {
	outcome := apply_expectation('git_remote', 'fail', Outcome{
		code:    'executable_not_found'
		message: 'executable "git" was not found'
	})
	assert !outcome.passed
	assert outcome.code == 'inconclusive_denial'
}

fn test_expect_fail_missing_working_directory_is_inconclusive() {
	outcome := apply_expectation('command', 'fail', Outcome{
		code:    'working_directory_not_found'
		message: 'working directory does not exist'
	})
	assert !outcome.passed
	assert outcome.code == 'inconclusive_denial'
}

fn test_run_check_expect_fail_on_reachable_http_status_mismatch() {
	mut server := &http.Server{
		addr:    '127.0.0.1:18471'
		handler: NotFoundHandler{}
	}
	spawn server.listen_and_serve()
	server.wait_till_running() or { panic(err) }
	defer {
		server.stop()
	}
	result := run_check(CheckConfig{
		name:          'Local endpoint is blocked'
		kind:          'http'
		target:        'http://127.0.0.1:18471/'
		expect:        'fail'
		expect_status: 200
		timeout_ms:    2000
		critical:      true
	})
	assert result.status == 'fail'
	assert result.code == 'unexpectedly_allowed'
}

struct NotFoundHandler {}

fn (h NotFoundHandler) handle(req http.Request) http.Response {
	mut res := http.Response{
		body: 'missing'
	}
	res.set_status(.not_found)
	return res
}
