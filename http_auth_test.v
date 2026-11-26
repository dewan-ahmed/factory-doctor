module main

import json
import os

fn test_expand_env_refs_substitutes_variables() {
	os.setenv('FD_TEST_TOKEN', 'secret-value', true)
	assert expand_env_refs('Bearer \${env:FD_TEST_TOKEN}')! == 'Bearer secret-value'
	assert expand_env_refs('literal')! == 'literal'
}

fn test_expand_env_refs_names_missing_variable() {
	os.unsetenv('FD_TEST_MISSING')
	if _ := expand_env_refs('Bearer \${env:FD_TEST_MISSING}') {
		assert false, 'expected missing variable error'
	} else {
		assert err.msg().contains('FD_TEST_MISSING')
	}
}

fn test_validate_http_headers_rejects_bad_references_and_names() {
	for headers in [{
		'Authorization': 'Bearer \${env:BAD-NAME}'
	}, {
		'Authorization': 'Bearer \${env:TOKEN'
	}, {
		'Bad Header': 'x'
	}, {
		'X-Test': 'a\r\nInjected: b'
	}] {
		if _ := validate_http_headers(headers) {
			assert false, 'expected ${headers} to be rejected'
		}
	}
	validate_http_headers({
		'Authorization': 'Bearer \${env:TOKEN}'
	})!
}

fn test_http_check_reports_missing_env_without_request() {
	os.unsetenv('FD_TEST_MISSING')
	result := run_check(CheckConfig{
		name:    'Registry'
		kind:    'http'
		target:  'https://registry.invalid/v2/'
		headers: {
			'Authorization': 'Bearer \${env:FD_TEST_MISSING}'
		}
	})
	assert result.status == 'fail'
	assert result.code == 'missing_env'
	assert result.message.contains('FD_TEST_MISSING')
}

fn test_report_never_contains_header_values() {
	os.setenv('FD_TEST_TOKEN', 'super-secret-token', true)
	result := run_check(CheckConfig{
		name:       'Registry'
		kind:       'http'
		target:     'http://127.0.0.1:1/v2/'
		timeout_ms: 500
		headers:    {
			'Authorization': 'Bearer \${env:FD_TEST_TOKEN}'
			'X-Literal':     'literal-secret'
		}
	})
	encoded := json.encode(build_report([result]))
	assert !encoded.contains('super-secret-token')
	assert !encoded.contains('literal-secret')
}

fn test_validate_config_rejects_unreadable_ca_file() {
	config := Config{
		checks: [
			CheckConfig{
				name:    'Registry'
				kind:    'http'
				target:  'https://registry.example.com'
				ca_file: '/nonexistent/corp-ca.pem'
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	} else {
		assert err.msg().contains('ca_file')
	}
}

fn test_validate_config_rejects_headers_on_other_kinds() {
	config := Config{
		checks: [
			CheckConfig{
				name:    'Git'
				kind:    'command'
				target:  'git'
				headers: {
					'X-Test': 'x'
				}
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	}
}

fn test_config_without_new_fields_still_decodes() {
	config := json.decode(Config,
		'{"version":1,"checks":[{"name":"API","kind":"http","target":"https://example.com"}]}')!
	assert config.checks[0].headers.len == 0
	assert config.checks[0].ca_file == ''
	validate_config(config)!
}

fn test_load_trust_bundle_appends_ca_file() {
	path := os.join_path(os.temp_dir(), 'factory-doctor-test-ca.pem')
	os.write_file(path, 'CORPORATE-CA')!
	defer {
		os.rm(path) or {}
	}
	bundle := load_trust_bundle(path)!
	assert bundle.ends_with('CORPORATE-CA')
}

fn test_http_error_code_detects_tls_verification() {
	assert http_error_code('net.mbedtls SSLConn.dial, mbedtls_ssl_handshake failed 3; ret: -9984') == 'tls_verification_failed'
	assert http_error_code('connection refused') == 'http_request_failed'
}
