module main

import net

fn test_parse_tcp_target_accepts_host_and_port() {
	host, port := parse_tcp_target('db.internal.example.com:5432') or { panic(err) }
	assert host == 'db.internal.example.com'
	assert port == 5432
}

fn test_parse_tcp_target_accepts_bracketed_ipv6() {
	host, port := parse_tcp_target('[::1]:5432') or { panic(err) }
	assert host == '::1'
	assert port == 5432
}

fn test_parse_tcp_target_rejects_invalid_targets() {
	for target in ['db.example.com', '::1:5432', '[::1]', 'db:0', 'db:70000', 'db:abc', ':5432',
		'tcp://db:5432'] {
		if _, _ := parse_tcp_target(target) {
			assert false, 'expected ${target} to be rejected'
		}
	}
}

fn test_validate_config_rejects_tcp_without_port() {
	config := Config{
		checks: [
			CheckConfig{
				name:   'Postgres'
				kind:   'tcp'
				target: 'db.example.com'
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	} else {
		assert err.msg().contains('invalid tcp target')
	}
}

fn test_validate_config_rejects_unknown_dns_family() {
	config := Config{
		checks: [
			CheckConfig{
				name:   'Registry'
				kind:   'dns'
				target: 'registry.example.com'
				args:   ['ipv5']
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	} else {
		assert err.msg().contains('ipv4')
	}
}

fn test_validate_config_rejects_dns_target_with_scheme() {
	config := Config{
		checks: [
			CheckConfig{
				name:   'Registry'
				kind:   'dns'
				target: 'https://registry.example.com'
			},
		]
	}
	if _ := validate_config(config) {
		assert false, 'expected validation error'
	}
}

fn test_tcp_check_connects_to_local_listener() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	result := run_check(CheckConfig{
		name:       'Local listener'
		kind:       'tcp'
		target:     '127.0.0.1:${port}'
		timeout_ms: 2_000
	})
	listener.close() or {}
	assert result.status == 'pass', result.message
	assert result.message.contains('127.0.0.1:${port}')
}

fn test_tcp_check_reports_refused_connection() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	listener.close() or {}
	result := run_check(CheckConfig{
		name:       'Closed port'
		kind:       'tcp'
		target:     '127.0.0.1:${port}'
		timeout_ms: 10_000
	})
	assert result.status == 'fail'
	assert result.code == 'tcp_connect_refused'
}

fn test_tcp_expect_fail_treats_refusal_as_blocked() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	listener.close() or {}
	result := run_check(CheckConfig{
		name:       'Egress blocked'
		kind:       'tcp'
		target:     '127.0.0.1:${port}'
		timeout_ms: 2_000
		expect:     'fail'
	})
	assert result.status == 'pass'
	assert result.code == 'blocked_as_expected'
}

fn test_dns_check_resolves_localhost() {
	result := run_check(CheckConfig{
		name:       'Localhost'
		kind:       'dns'
		target:     'localhost'
		timeout_ms: 2_000
	})
	assert result.status == 'pass', result.message
	assert result.message.starts_with('resolved ')
}

fn test_dns_outcome_requires_listed_families() {
	assert dns_outcome(1, 0, ['ipv4']).passed
	missing := dns_outcome(1, 0, ['ipv6'])
	assert !missing.passed
	assert missing.code == 'dns_family_missing'
	empty := dns_outcome(0, 0, []string{})
	assert empty.code == 'dns_resolution_failed'
}

fn test_dns_family_missing_is_not_a_denial() {
	outcome := apply_expectation('dns', 'fail', Outcome{
		code:    'dns_family_missing'
		message: 'no ipv6 address'
	})
	assert !outcome.passed
	assert outcome.code == 'inconclusive_denial'
}

fn test_wait_for_attempt_times_out() {
	result := chan NetworkAttempt{cap: 1}
	outcome := wait_for_attempt(result, 20, 'tcp_connect_timeout')
	assert !outcome.passed
	assert outcome.code == 'tcp_connect_timeout'
}

fn test_bootstrap_rejects_invalid_network_verification() {
	for verify in [Verification{
		kind:   'tcp'
		target: 'db.example.com'
	}, Verification{
		kind:   'tcp'
		target: 'db.example.com:5432'
		args:   ['x']
	}, Verification{
		kind:   'dns'
		target: 'db.example.com'
		args:   ['ipv5']
	}] {
		profile := BootstrapProfile{
			name:         'Test'
			requirements: [
				Requirement{
					id:       'network.db'
					category: 'network'
					name:     'Database'
					guidance: 'Open the port.'
					verify:   verify
				},
			]
		}
		if _ := validate_bootstrap_profile(profile) {
			assert false, 'expected ${verify.kind} ${verify.target} to be rejected'
		}
	}
}

fn test_tcp_check_tries_every_resolved_address() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	port := listener.addr() or { panic(err) }.port() or { panic(err) }
	result := run_check(CheckConfig{
		name:       'localhost'
		kind:       'tcp'
		target:     'localhost:${port}'
		timeout_ms: 2_000
	})
	listener.close() or {}
	assert result.status == 'pass', result.message
}
