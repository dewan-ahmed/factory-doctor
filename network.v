module main

import net
import time

struct NetworkAttempt {
	code    string
	message string
	passed  bool
}

// parse_tcp_target splits host:port. IPv6 literals must use brackets, as in
// [::1]:5432, so the port is never ambiguous.
fn parse_tcp_target(target string) !(string, int) {
	mut host := ''
	mut port_text := ''
	if target.starts_with('[') {
		close := target.index(']') or { return error('IPv6 target is missing "]"') }
		host = target[1..close]
		rest := target[close + 1..]
		if !rest.starts_with(':') {
			return error('target must include a port, as in [::1]:5432')
		}
		port_text = rest[1..]
	} else {
		if target.count(':') > 1 {
			return error('wrap IPv6 addresses in brackets, as in [::1]:5432')
		}
		if !target.contains(':') {
			return error('target must include a port, as in db.example.com:5432')
		}
		host = target.all_before_last(':')
		port_text = target.all_after_last(':')
	}
	if host == '' {
		return error('target is missing a host')
	}
	if host.contains('/') || host.contains(' ') {
		return error('target must be host:port without a scheme or path')
	}
	if port_text == '' || !port_text.bytes().all(it.is_digit()) {
		return error('port must be a number')
	}
	port := port_text.int()
	if port < 1 || port > 65_535 {
		return error('port must be between 1 and 65535')
	}
	return host, port
}

fn validate_dns_target(target string) ! {
	if target.contains('/') || target.contains(' ') {
		return error('target must be a hostname without a scheme, port, or path')
	}
}

fn validate_dns_families(families []string) ! {
	for family in families {
		if family !in ['ipv4', 'ipv6'] {
			return error('args may only contain "ipv4" or "ipv6"')
		}
	}
}

// validate_network_check rejects tcp and dns settings that would otherwise be
// ignored or fail only at run time.
fn validate_network_check(kind string, target string, args []string) ! {
	if kind == 'tcp' {
		parse_tcp_target(target) or { return error('has invalid tcp target: ${err.msg()}') }
		if args.len > 0 {
			return error('tcp checks do not take args')
		}
	}
	if kind == 'dns' {
		validate_dns_target(target) or { return error('has invalid dns target: ${err.msg()}') }
		validate_dns_families(args)!
	}
}

fn join_host_port(host string, port int) string {
	return if host.contains(':') { '[${host}]:${port}' } else { '${host}:${port}' }
}

fn check_tcp(check CheckConfig) Outcome {
	host, port := parse_tcp_target(check.target) or {
		return Outcome{
			code:    'invalid_target'
			message: err.msg()
		}
	}
	result := chan NetworkAttempt{cap: 1}
	spawn dial_tcp_attempt(host, port, result)
	return wait_for_attempt(result, check.timeout_ms, 'tcp_connect_timeout')
}

fn dial_tcp_attempt(host string, port int, result chan NetworkAttempt) {
	target := join_host_port(host, port)
	addrs := net.resolve_addrs_fuzzy(target, .tcp) or {
		result <- NetworkAttempt{
			code:    'dns_resolution_failed'
			message: 'could not resolve host: ${err.msg()}'
		}
		return
	}
	if addrs.len == 0 {
		result <- NetworkAttempt{
			code:    'dns_resolution_failed'
			message: 'could not resolve host: no addresses returned'
		}
		return
	}
	// Dial every address at once so one address that drops packets cannot use
	// up the timeout before a reachable one is tried. Addr.str() drops IPv6
	// zone IDs, so scoped targets are dialed by name.
	dials := chan NetworkAttempt{cap: addrs.len}
	for addr in addrs {
		spawn dial_tcp_address(if host.contains('%') { target } else { addr.str() }, dials)
	}
	mut refused := false
	mut last_error := ''
	for _ in 0 .. addrs.len {
		attempt := <-dials
		if attempt.passed {
			result <- attempt
			return
		}
		refused = refused || attempt.code == 'tcp_connect_refused'
		last_error = attempt.message
	}
	result <- NetworkAttempt{
		code:    if refused { 'tcp_connect_refused' } else { 'tcp_connect_failed' }
		message: 'could not connect to any of ${addrs.len} address(es): ${last_error}'
	}
}

fn dial_tcp_address(address string, dials chan NetworkAttempt) {
	mut conn := net.dial_tcp(address) or {
		dials <- NetworkAttempt{
			code:    if err.msg().contains('socket error: ${int(C.ECONNREFUSED)};') {
				'tcp_connect_refused'
			} else {
				'tcp_connect_failed'
			}
			message: err.msg().all_after_last('\t').trim_space()
		}
		return
	}
	conn.close() or {}
	dials <- NetworkAttempt{
		passed:  true
		code:    'ok'
		message: 'connected to ${address}'
	}
}

fn check_dns(check CheckConfig) Outcome {
	result := chan NetworkAttempt{cap: 1}
	spawn resolve_attempt(check.target, check.args, result)
	return wait_for_attempt(result, check.timeout_ms, 'dns_resolution_failed')
}

fn resolve_attempt(host string, families []string, result chan NetworkAttempt) {
	addrs := net.resolve_addrs(host, .unspec, .tcp) or {
		result <- NetworkAttempt{
			code:    'dns_resolution_failed'
			message: err.msg()
		}
		return
	}
	mut ipv4 := 0
	mut ipv6 := 0
	for addr in addrs {
		match addr.family() {
			.ip { ipv4++ }
			.ip6 { ipv6++ }
			else {}
		}
	}
	result <- dns_outcome(ipv4, ipv6, families)
}

fn dns_outcome(ipv4 int, ipv6 int, families []string) NetworkAttempt {
	if ipv4 + ipv6 == 0 {
		return NetworkAttempt{
			code:    'dns_resolution_failed'
			message: 'no addresses returned'
		}
	}
	summary := 'resolved ${ipv4 + ipv6} address(es): ${ipv4} IPv4, ${ipv6} IPv6'
	for family in families {
		if (family == 'ipv4' && ipv4 == 0) || (family == 'ipv6' && ipv6 == 0) {
			return NetworkAttempt{
				code:    'dns_family_missing'
				message: 'no ${family} address; ${summary}'
			}
		}
	}
	return NetworkAttempt{
		passed:  true
		code:    'ok'
		message: summary
	}
}

// wait_for_attempt bounds a blocking resolver or connect call. A timed-out
// attempt keeps running in its thread until the process exits.
fn wait_for_attempt(result chan NetworkAttempt, timeout_ms int, timeout_code string) Outcome {
	mut outcome := Outcome{
		code:    timeout_code
		message: 'timed out after ${timeout_ms} ms'
	}
	select {
		attempt := <-result {
			outcome = Outcome{
				passed:  attempt.passed
				code:    attempt.code
				message: attempt.message
			}
		}
		i64(timeout_ms) * time.millisecond {}
	}
	return outcome
}
