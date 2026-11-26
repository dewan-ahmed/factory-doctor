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
		target:     'https://127.0.0.1:1/v2/'
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
	os.write_file(path, '-----BEGIN CERTIFICATE-----\nCORPORATE-CA')!
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

fn test_validate_config_rejects_headers_over_plain_http() {
	config := Config{
		checks: [
			CheckConfig{
				name:    'Registry'
				kind:    'http'
				target:  'http://registry.example.com/v2/'
				headers: {
					'Authorization': 'Bearer x'
				}
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	} else {
		assert err.msg().contains('https://')
	}
}

fn test_validate_http_headers_caps_header_count() {
	mut headers := map[string]string{}
	for index in 0 .. max_custom_headers + 1 {
		headers['X-Header-${index}'] = 'x'
	}
	if _ := validate_http_headers(headers) {
		assert false, 'expected too many headers to be rejected'
	}
}

fn test_cookie_header_becomes_request_cookies() {
	os.setenv('FD_TEST_SESSION', 'abc123', true)
	auth := build_http_auth({
		'Cookie': 'session=\${env:FD_TEST_SESSION}; theme=dark'
	})!
	assert auth.cookies == {
		'session': 'abc123'
		'theme':   'dark'
	}
	assert !auth.header.contains_custom('Cookie')
	if _ := validate_http_headers({
		'Cookie': 'not-a-pair'
	})
	{
		assert false, 'expected malformed cookie to be rejected'
	}
}

fn test_redact_scrubs_header_values() {
	assert redact('server echoed Bearer abc and abc', ['Bearer abc', 'abc']) == 'server echoed [redacted] and [redacted]'
}

fn test_validate_config_rejects_ca_file_without_certificate() {
	path := os.join_path(os.temp_dir(), 'factory-doctor-not-a-ca.pem')
	os.write_file(path, 'garbage')!
	defer {
		os.rm(path) or {}
	}
	config := Config{
		checks: [
			CheckConfig{
				name:    'Registry'
				kind:    'http'
				target:  'https://registry.example.com'
				ca_file: path
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	} else {
		assert err.msg().contains('PEM')
	}
}

fn test_http_error_code_flags_bad_trust_configuration() {
	assert http_error_code('net.mbedtls SSLConn.init, failed to set certificates, ret: -8576') == 'tls_configuration_invalid'
}

fn test_cookie_made_entirely_of_env_reference_is_accepted() {
	validate_http_headers({
		'Cookie': '\${env:SESSION_COOKIE}'
	})!
	os.setenv('FD_TEST_COOKIE', 'session=abc; theme=dark', true)
	auth := build_http_auth({
		'Cookie': '\${env:FD_TEST_COOKIE}'
	})!
	assert auth.cookies['session'] == 'abc'
}

fn test_http_error_code_detects_schannel_trust_failures() {
	assert http_error_code('SEC_E_UNTRUSTED_ROOT: The certificate chain was issued by an authority that is not trusted') == 'tls_verification_failed'
}
