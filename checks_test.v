module main

import os
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

fn git_fixture() string {
	root := os.join_path(os.temp_dir(), 'factory-doctor-diff-${os.getpid()}')
	os.rmdir_all(root) or {}
	os.mkdir_all(root) or { panic(err) }
	git := 'git -C ${os.quoted_path(root)} -c user.name=test -c user.email=test@example.com'
	os.write_file(os.join_path(root, 'main.txt'), 'base\n') or { panic(err) }
	for command in ['git init -q -b main ${os.quoted_path(root)}', '${git} add .',
		'${git} commit -q -m base', '${git} checkout -q -b feature'] {
		assert os.execute(command).exit_code == 0, command
	}
	os.write_file(os.join_path(root, 'main.txt'), 'base\none\ntwo\nthree\n') or { panic(err) }
	os.write_file(os.join_path(root, 'go.lock'), 'a\nb\nc\nd\ne\nf\n') or { panic(err) }
	os.write_file(os.join_path(root, 'bin.dat'), [u8(0), 1, 2].bytestr()) or { panic(err) }
	assert os.execute('${git} add . && ${git} commit -q -m change').exit_code == 0
	os.write_file(os.join_path(root, 'main.txt'), 'base\none\ntwo\nthree\nfour\n') or { panic(err) }
	return root
}

fn diff_check(root string, max_files int, max_lines int, exclude []string) CheckConfig {
	return CheckConfig{
		name:              'reviewable'
		kind:              'diff'
		target:            'main'
		working_directory: root
		max_files:         max_files
		max_lines:         max_lines
		exclude:           exclude
	}
}

fn test_diff_check_counts_committed_and_uncommitted_changes() {
	root := git_fixture()
	defer {
		os.rmdir_all(root) or {}
	}
	ok := check_diff(diff_check(root, 5, 100, []))
	assert ok.passed
	assert ok.message == '2 files, 10 lines changed against main'
	over := check_diff(diff_check(root, 0, 5, []))
	assert !over.passed
	assert over.code == 'diff_too_large'
	assert over.message.contains('largest: go.lock (6), main.txt (4)')
	excluded := check_diff(diff_check(root, 1, 5, ['*.lock']))
	assert excluded.passed
	assert excluded.message == '1 files, 4 lines changed against main'
}

fn test_diff_check_reports_bad_base_and_directory() {
	root := git_fixture()
	defer {
		os.rmdir_all(root) or {}
	}
	bad := check_diff(CheckConfig{ ...diff_check(root, 1, 0, []), target: 'no-such-ref' })
	assert bad.code == 'command_failed'
	missing := check_diff(diff_check('/nonexistent/repo', 1, 0, []))
	assert missing.code == 'working_directory_not_found'
}

fn test_diff_config_validation() {
	base := Config{
		checks: [
			CheckConfig{
				name:   'reviewable'
				kind:   'diff'
				target: 'origin/main'
			},
		]
	}
	if _ := validate_config(base) {
		assert false, 'expected missing limits to fail'
	}
	if _ := validate_config(Config{
		checks: [
			CheckConfig{
				...base.checks[0]
				max_lines: 10
				target:    '--output=x'
			},
		]
	})
	{
		assert false, 'expected option-like target to fail'
	}
	validate_config(Config{
		checks: [CheckConfig{ ...base.checks[0], max_lines: 10 }]
	}) or { assert false, err.msg() }
}

fn test_glob_match_for_excludes() {
	assert glob_match('*.lock', 'go.lock')
	assert glob_match('testdata/**', 'testdata/a/b.json')
	assert !glob_match('testdata/**', 'src/testdata.v')
	assert glob_match('**/generated/**', 'src/generated/a.v')
	assert glob_match('**/generated/**', 'generated/a.v')
	assert !glob_match('**/generated/**', 'src/not-generated/a.v')
}

fn test_parse_numstat_handles_renames_and_binary() {
	entries := parse_numstat('1\t2\ta.v\x00-\t-\tbin.dat\x00' +
		'0\t3\t\x00old.lock\x00new/name.txt\x00')
	assert entries.len == 3
	assert entries[0].paths == ['a.v']
	assert entries[0].changed == 3
	assert entries[1].binary
	assert entries[2].paths == ['old.lock', 'new/name.txt']
	assert diff_excluded('*.lock', entries[2].paths)
	assert !diff_excluded('*.lock', entries[0].paths)
}
