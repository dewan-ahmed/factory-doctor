module main

import net.http
import os

// Certificate bundles shipped by common Linux distributions, Alpine, and macOS.
const system_ca_bundles = ['/etc/ssl/certs/ca-certificates.crt', '/etc/pki/tls/certs/ca-bundle.crt',
	'/etc/ssl/ca-bundle.pem', '/etc/ssl/cert.pem', '/usr/local/etc/openssl@3/cert.pem',
	'/opt/homebrew/etc/openssl@3/cert.pem']

// mbedtls handshake results that mean the peer certificate was not trusted:
// X509_CERT_VERIFY_FAILED, SSL_CA_CHAIN_REQUIRED, and SSL_BAD_CERTIFICATE.
const tls_verification_errors = ['ret: -9984', 'ret: -30336', 'ret: -31232']
const tls_configuration_errors = ['failed to set certificates', 'mbedtls_x509_crt_parse']
const max_custom_headers = 32

// HttpAuth is the request material built from a check's headers. secrets
// holds every expanded value so it can be scrubbed from error messages.
struct HttpAuth {
	header  http.Header
	cookies map[string]string
	secrets []string
}

// expand_env_refs replaces ${env:NAME} with the variable's value. It fails on
// an unset or empty variable and names the variable, never a value.
fn expand_env_refs(value string) !string {
	mut out := []u8{cap: value.len}
	mut index := 0
	for index < value.len {
		if value[index..].starts_with('\${env:') {
			end := value[index..].index('}') or { return error('unterminated \${env:} reference') }
			name := value[index + 6..index + end]
			if !is_env_name(name) {
				return error('invalid environment variable name "${name}"')
			}
			resolved := os.getenv(name)
			if resolved == '' {
				return error('environment variable ${name} is not set')
			}
			out << resolved.bytes()
			index += end + 1
			continue
		}
		out << value[index]
		index++
	}
	return out.bytestr()
}

fn is_env_name(name string) bool {
	if name == '' || name[0].is_digit() {
		return false
	}
	return name.bytes().all(it.is_letter() || it.is_digit() || it == `_`)
}

// validate_env_refs checks reference syntax without reading the environment,
// so config validation does not depend on where it runs.
fn validate_env_refs(value string) ! {
	mut rest := value
	for {
		start := rest.index('\${env:') or { return }
		end := rest[start..].index('}') or { return error('unterminated \${env:} reference') }
		name := rest[start + 6..start + end]
		if !is_env_name(name) {
			return error('invalid environment variable name "${name}"')
		}
		rest = rest[start + end + 1..]
	}
}

fn validate_http_headers(headers map[string]string) ! {
	if headers.len > max_custom_headers {
		return error('at most ${max_custom_headers} headers are supported')
	}
	for name, value in headers {
		if name.trim_space() == '' || name.contains_any('\r\n:') || name.contains(' ') {
			return error('header name "${name}" is invalid')
		}
		if value.contains_any('\r\n') {
			return error('header ${name} value must not contain line breaks')
		}
		validate_env_refs(value) or { return error('header ${name}: ${err.msg()}') }
		if name.to_lower() == 'cookie' && !value.contains('\${env:') {
			parse_cookie_header(value) or { return error('header ${name}: ${err.msg()}') }
		}
	}
}

// parse_cookie_header splits "a=1; b=2" into a map. V's HTTP/1.1 client
// writes cookies from Request.cookies and drops a raw Cookie header.
fn parse_cookie_header(value string) !map[string]string {
	mut cookies := map[string]string{}
	for pair in value.split(';') {
		trimmed := pair.trim_space()
		if trimmed == '' {
			continue
		}
		name := trimmed.all_before('=').trim_space()
		if !trimmed.contains('=') || name == '' {
			return error('cookies must be name=value pairs separated by ";"')
		}
		cookies[name] = trimmed.all_after('=').trim_space()
	}
	return cookies
}

fn redact(message string, secrets []string) string {
	mut out := message
	for secret in secrets {
		if secret.len > 0 {
			out = out.replace(secret, '[redacted]')
		}
	}
	return out
}

fn build_http_auth(headers map[string]string) !HttpAuth {
	mut expanded := map[string]string{}
	mut cookies := map[string]string{}
	mut secrets := []string{}
	for name, raw in headers {
		value := expand_env_refs(raw) or { return error('header ${name}: ${err.msg()}') }
		secrets << value
		if name.to_lower() == 'cookie' {
			cookies = parse_cookie_header(value) or { return error('header ${name}: ${err.msg()}') }
			for _, cookie in cookies {
				secrets << cookie
			}
			continue
		}
		expanded[name] = value
	}
	return HttpAuth{
		header:  http.new_custom_header_from_map(expanded)!
		cookies: cookies
		secrets: secrets
	}
}

// load_trust_bundle returns the system CA bundle plus ca_file, so a corporate
// CA can be added without losing public roots. SSL_CERT_FILE overrides the
// system bundle location, as it does for OpenSSL and Git.
fn load_trust_bundle(ca_file string) !string {
	mut parts := []string{}
	system_bundle := find_system_ca_bundle()
	if system_bundle != '' {
		parts << os.read_file(system_bundle) or {
			return error('could not read CA bundle ${system_bundle}')
		}
	}
	if ca_file != '' {
		parts << os.read_file(ca_file) or { return error('could not read ca_file ${ca_file}') }
	}
	if parts.len == 0 {
		return error('no CA bundle found; set ca_file or SSL_CERT_FILE')
	}
	return parts.join('\n')
}

fn find_system_ca_bundle() string {
	from_env := os.getenv('SSL_CERT_FILE')
	if from_env != '' {
		return from_env
	}
	for path in system_ca_bundles {
		if os.is_file(path) {
			return path
		}
	}
	return ''
}

fn http_error_code(message string) string {
	for code in tls_configuration_errors {
		if message.contains(code) {
			return 'tls_configuration_invalid'
		}
	}
	for code in tls_verification_errors {
		if message.contains(code) {
			return 'tls_verification_failed'
		}
	}
	// SChannel on Windows reports trust failures as SEC_E_/CERT_E_ codes.
	lower := message.to_lower()
	if lower.contains('certificate') || message.contains('SEC_E_') || message.contains('CERT_E_') {
		return 'tls_verification_failed'
	}
	return 'http_request_failed'
}
