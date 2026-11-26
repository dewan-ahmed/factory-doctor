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
		if check.kind != 'http' && (check.headers.len > 0 || check.ca_file != '') {
			return error('check "${check.name}" headers and ca_file are only supported for http checks')
		}
		if check.kind == 'http' {
			validate_http_headers(check.headers) or {
				return error('check "${check.name}" ${err.msg()}')
			}
			if check.headers.len > 0 && !check.target.to_lower().starts_with('https://') {
				return error('check "${check.name}" headers require an https:// target')
			}
			if check.ca_file != '' {
				validate_ca_file(check.ca_file) or {
					return error('check "${check.name}" ${err.msg()}')
				}
			}
		}
		validate_network_check(check.kind, check.target, check.args) or {
			return error('check "${check.name}" ${err.msg()}')
		}
	}
}

fn validate_ca_file(path string) ! {
	$if windows {
		return error('ca_file is not supported on Windows; add the CA to the Windows certificate store')
	}
	if !os.is_file(path) || !os.is_readable(path) {
		return error('ca_file is not a readable file')
	}
	content := os.read_file(path) or { return error('ca_file is not a readable file') }
	if !content.contains('-----BEGIN CERTIFICATE-----') {
		return error('ca_file does not contain a PEM certificate')
	}
}
