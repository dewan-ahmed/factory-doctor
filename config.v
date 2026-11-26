module main

import json
import os

fn load_config(path string) !Config {
	content := os.read_file(path)!
	config := json.decode(Config, content)!
	validate_config(config)!
	return config
}

fn validate_config(config Config) ! {
	if config.version != 1 {
		return error('unsupported config version ${config.version}; expected 1')
	}
	if config.checks.len == 0 {
		return error('config must contain at least one check')
	}
	if config.concurrency < 1 {
		return error('concurrency must be at least 1')
	}
	if config.deadline_ms < 0 {
		return error('deadline_ms must not be negative')
	}
	for index, check in config.checks {
		if check.name.trim_space() == '' {
			return error('check ${index + 1} is missing a name')
		}
		if check.kind !in ['http', 'command', 'git_remote', 'file', 'env', 'tcp', 'dns', 'diff'] {
			return error('check "${check.name}" has unsupported kind "${check.kind}"')
		}
		if check.target.trim_space() == '' {
			return error('check "${check.name}" is missing a target')
		}
		if check.timeout_ms < 1 {
			return error('check "${check.name}" timeout_ms must be positive')
		}
		if check.expect !in ['pass', 'fail'] {
			return error('check "${check.name}" expect must be "pass" or "fail"')
		}
		if check.kind == 'diff' && check.max_files < 1 && check.max_lines < 1 {
			return error('check "${check.name}" diff requires max_files or max_lines')
		}
		if check.kind == 'diff' && check.target.starts_with('-') {
			return error('check "${check.name}" diff target must be a git ref')
		}
		if check.kind == 'http' && check.expect_status !in 100..600 {
			return error('check "${check.name}" expect_status must be an HTTP status code')
		}
		validate_network_check(check.kind, check.target, check.args) or {
			return error('check "${check.name}" ${err.msg()}')
		}
	}
}
