module main

import json
import os
import time

const bootstrap_categories = ['identity', 'secrets', 'source_control', 'connectors', 'environments',
	'network', 'agents', 'models', 'budgets', 'observability', 'policy']
const verification_kinds = ['manual', 'env', 'http', 'command', 'git_remote', 'file', 'tcp', 'dns']
const bootstrap_template = $embed_file('examples/factory-bootstrap.json')

pub struct BootstrapProfile {
pub:
	version      int = 1
	name         string
	requirements []Requirement
}

pub struct Requirement {
pub:
	id        string
	category  string
	name      string
	rationale string
	guidance  string
	docs_url  string
	required  bool = true
	confirmed bool
	verify    Verification
}

pub struct Verification {
pub:
	kind              string = 'manual'
	target            string
	args              []string
	expect_status     int = 200
	timeout_ms        int = 3_000
	working_directory string
}

pub struct RequirementResult {
pub:
	id          string
	category    string
	name        string
	required    bool
	kind        string
	target      string
	status      string
	code        string
	message     string
	guidance    string
	docs_url    string
	duration_ms i64
}

pub struct BootstrapSummary {
pub:
	total   int
	passed  int
	missing int
	warned  int
	manual  int
}

pub struct BootstrapReport {
pub:
	version      int = 1
	profile      string
	status       string
	requirements []RequirementResult
	summary      BootstrapSummary
}

fn load_bootstrap_profile(path string) !BootstrapProfile {
	content := os.read_file(path)!
	profile := json.decode(BootstrapProfile, content)!
	validate_bootstrap_profile(profile)!
	return profile
}

fn validate_bootstrap_profile(profile BootstrapProfile) ! {
	if profile.version != 1 {
		return error('unsupported bootstrap profile version ${profile.version}; expected 1')
	}
	if profile.requirements.len == 0 {
		return error('bootstrap profile must contain at least one requirement')
	}
	mut seen := map[string]bool{}
	for index, requirement in profile.requirements {
		label := if requirement.id == '' {
			'requirement ${index + 1}'
		} else {
			'requirement "${requirement.id}"'
		}
		if requirement.id.trim_space() == '' {
			return error('${label} is missing an id')
		}
		if requirement.id in seen {
			return error('${label} is duplicated')
		}
		seen[requirement.id] = true
		if requirement.name.trim_space() == '' {
			return error('${label} is missing a name')
		}
		if requirement.category !in bootstrap_categories {
			return error('${label} has unsupported category "${requirement.category}"')
		}
		if requirement.guidance.trim_space() == '' {
			return error('${label} is missing guidance')
		}
		verify := requirement.verify
		if verify.kind !in verification_kinds {
			return error('${label} has unsupported verify kind "${verify.kind}"')
		}
		if verify.kind == 'manual' {
			continue
		}
		if requirement.confirmed {
			return error('${label} can set confirmed only for manual verification')
		}
		if verify.target.trim_space() == '' {
			return error('${label} verify is missing a target')
		}
		if verify.timeout_ms < 1 {
			return error('${label} verify timeout_ms must be positive')
		}
		if verify.kind == 'http' && verify.expect_status !in 100..600 {
			return error('${label} verify expect_status must be an HTTP status code')
		}
		validate_network_check(verify.kind, verify.target, verify.args) or {
			return error('${label} verify ${err.msg()}')
		}
	}
}

fn run_bootstrap(profile BootstrapProfile) BootstrapReport {
	mut results := []RequirementResult{cap: profile.requirements.len}
	for requirement in profile.requirements {
		results << run_requirement(requirement)
	}
	return build_bootstrap_report(profile.name, results)
}

fn run_requirement(requirement Requirement) RequirementResult {
	verify := requirement.verify
	if verify.kind == 'manual' && requirement.confirmed {
		return RequirementResult{
			id:       requirement.id
			category: requirement.category
			name:     requirement.name
			required: requirement.required
			kind:     verify.kind
			status:   'pass'
			code:     'manually_confirmed'
			message:  'confirmed in profile'
		}
	}
	if verify.kind == 'manual' {
		return RequirementResult{
			id:       requirement.id
			category: requirement.category
			name:     requirement.name
			required: requirement.required
			kind:     verify.kind
			status:   'manual'
			code:     'manual_confirmation_required'
			message:  'cannot be verified automatically'
			guidance: requirement.guidance
			docs_url: requirement.docs_url
		}
	}
	check := CheckConfig{
		name:              requirement.name
		kind:              verify.kind
		target:            verify.target
		args:              verify.args
		expect_status:     verify.expect_status
		timeout_ms:        verify.timeout_ms
		critical:          requirement.required
		working_directory: verify.working_directory
	}
	started := time.now()
	result := run_check(check)
	status := match result.status {
		'pass' { 'pass' }
		'fail' { 'missing' }
		else { 'warn' }
	}

	return RequirementResult{
		id:          requirement.id
		category:    requirement.category
		name:        requirement.name
		required:    requirement.required
		kind:        verify.kind
		target:      result.target
		status:      status
		code:        result.code
		message:     result.message
		guidance:    if status == 'pass' { '' } else { requirement.guidance }
		docs_url:    if status == 'pass' { '' } else { requirement.docs_url }
		duration_ms: time.since(started).milliseconds()
	}
}

fn build_bootstrap_report(profile string, results []RequirementResult) BootstrapReport {
	mut passed := 0
	mut missing := 0
	mut warned := 0
	mut manual := 0
	for result in results {
		match result.status {
			'pass' { passed++ }
			'missing' { missing++ }
			'warn' { warned++ }
			'manual' { manual++ }
			else {}
		}
	}
	return BootstrapReport{
		profile:      profile
		status:       if missing > 0 {
			'not_ready'
		} else if warned > 0 || manual > 0 {
			'action_required'
		} else {
			'ready'
		}
		requirements: results
		summary:      BootstrapSummary{
			total:   results.len
			passed:  passed
			missing: missing
			warned:  warned
			manual:  manual
		}
	}
}

fn bootstrap_exit_code(report BootstrapReport, strict bool) int {
	if report.status == 'not_ready' {
		return 1
	}
	if strict && report.status != 'ready' {
		return 1
	}
	return 0
}

fn write_bootstrap_template(path string, force bool) ! {
	if os.exists(path) && !force {
		return error('${path} already exists; use --force to overwrite it')
	}
	os.write_file(path, bootstrap_template.to_string())!
}

fn print_bootstrap_report(report BootstrapReport) {
	if report.profile != '' {
		println('Bootstrap profile: ${report.profile}')
	}
	for category in bootstrap_categories {
		items := report.requirements.filter(it.category == category)
		if items.len == 0 {
			continue
		}
		println('')
		println(category)
		for item in items {
			level := if item.required { 'required' } else { 'recommended' }
			println('  ${item.status.to_upper():-7}  ${item.name} [${item.id}, ${level}]  ${item.message}')
			if item.guidance != '' {
				println('           next: ${item.guidance}')
			}
			if item.docs_url != '' {
				println('           docs: ${item.docs_url}')
			}
		}
	}
	println('')
	println('${report.status.to_upper()}: ${report.summary.passed} passed, ${report.summary.missing} missing, ${report.summary.warned} warned, ${report.summary.manual} manual')
}
