module main

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
