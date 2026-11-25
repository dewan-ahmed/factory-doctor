module main

import json
import os

fn test_example_bootstrap_profile_is_valid() {
	profile := json.decode(BootstrapProfile, bootstrap_template.to_string())!
	validate_bootstrap_profile(profile)!
	mut categories := map[string]bool{}
	for requirement in profile.requirements {
		categories[requirement.category] = true
	}
	for category in bootstrap_categories {
		assert category in categories, 'example profile is missing ${category}'
	}
}

fn test_verify_defaults_to_manual_when_omitted() {
	profile := json.decode(BootstrapProfile,
		'{"version":1,"requirements":[{"id":"policy.review","category":"policy","name":"Review","guidance":"Require review."}]}')!
	validate_bootstrap_profile(profile)!
	result := run_requirement(profile.requirements[0])
	assert result.status == 'manual'
	assert result.code == 'manual_confirmation_required'
}

fn test_confirmed_manual_requirement_passes() {
	result := run_requirement(Requirement{
		id:        'budgets.limits'
		category:  'budgets'
		name:      'Limits'
		guidance:  'Set limits.'
		confirmed: true
	})
	assert result.status == 'pass'
	assert result.code == 'manually_confirmed'
	assert result.guidance == ''
}

fn test_validate_bootstrap_profile_rejects_bad_requirements() {
	cases := {
		'unsupported category': Requirement{
			id:       'x'
			category: 'vendor_x'
			name:     'X'
			guidance: 'Do X.'
		}
		'missing guidance':     Requirement{
			id:       'x'
			category: 'policy'
			name:     'X'
		}
		'missing a target':     Requirement{
			id:       'x'
			category: 'secrets'
			name:     'X'
			guidance: 'Do X.'
			verify:   Verification{
				kind: 'env'
			}
		}
		'confirmed only':       Requirement{
			id:        'x'
			category:  'secrets'
			name:      'X'
			guidance:  'Do X.'
			confirmed: true
			verify:    Verification{
				kind:   'env'
				target: 'X'
			}
		}
	}
	for expected, requirement in cases {
		if _ := validate_bootstrap_profile(BootstrapProfile{
			requirements: [requirement]
		})
		{
			assert false, 'expected error containing ${expected}'
		} else {
			assert err.msg().contains(expected), err.msg()
		}
	}
}

fn test_validate_bootstrap_profile_rejects_duplicate_ids() {
	requirement := Requirement{
		id:       'policy.review'
		category: 'policy'
		name:     'Review'
		guidance: 'Require review.'
	}
	if _ := validate_bootstrap_profile(BootstrapProfile{
		requirements: [requirement, requirement]
	})
	{
		assert false, 'expected duplicate error'
	} else {
		assert err.msg().contains('duplicated')
	}
}

fn test_env_requirement_never_reports_secret_value() {
	os.setenv('FACTORY_DOCTOR_TEST_SECRET', 'super-secret-value', true)
	defer {
		os.unsetenv('FACTORY_DOCTOR_TEST_SECRET')
	}
	report := build_bootstrap_report('test', [
		run_requirement(Requirement{
			id:       'secrets.test'
			category: 'secrets'
			name:     'Test secret'
			guidance: 'Set it.'
			verify:   Verification{
				kind:   'env'
				target: 'FACTORY_DOCTOR_TEST_SECRET'
			}
		}),
	])
	assert report.status == 'ready'
	assert !json.encode(report).contains('super-secret-value')
}

fn test_missing_required_env_is_not_ready() {
	result := run_requirement(Requirement{
		id:       'secrets.absent'
		category: 'secrets'
		name:     'Absent secret'
		guidance: 'Set it.'
		docs_url: 'https://example.com/secrets'
		verify:   Verification{
			kind:   'env'
			target: 'FACTORY_DOCTOR_TEST_ABSENT'
		}
	})
	assert result.status == 'missing'
	assert result.code == 'env_not_set'
	assert result.guidance == 'Set it.'
	assert result.docs_url == 'https://example.com/secrets'
	report := build_bootstrap_report('test', [result])
	assert report.status == 'not_ready'
	assert bootstrap_exit_code(report, false) == 1
}

fn test_bootstrap_status_and_strict_exit_code() {
	report := build_bootstrap_report('test', [
		RequirementResult{
			status: 'pass'
		},
		RequirementResult{
			status: 'warn'
		},
		RequirementResult{
			status: 'manual'
		},
	])
	assert report.status == 'action_required'
	assert report.summary.passed == 1
	assert report.summary.warned == 1
	assert report.summary.manual == 1
	assert bootstrap_exit_code(report, false) == 0
	assert bootstrap_exit_code(report, true) == 1
	ready := build_bootstrap_report('test', [RequirementResult{
		status: 'pass'
	}])
	assert ready.status == 'ready'
	assert bootstrap_exit_code(ready, true) == 0
}

fn test_write_bootstrap_template_refuses_overwrite() {
	path := os.join_path(os.temp_dir(), 'factory-doctor-bootstrap-test.json')
	os.write_file(path, '{}')!
	defer {
		os.rm(path) or {}
	}
	if _ := write_bootstrap_template(path, false) {
		assert false, 'expected overwrite error'
	} else {
		assert err.msg().contains('--force')
	}
	write_bootstrap_template(path, true)!
	assert os.read_file(path)!.contains('"requirements"')
}
