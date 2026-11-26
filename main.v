module main

import json
import os

fn main() {
	if os.args.len < 2 || os.args[1] in ['help', '--help', '-h'] {
		print_help()
		return
	}
	if os.args[1] == 'bootstrap' {
		exit(run_bootstrap_command(os.args[2..]))
	}
	if os.args[1] != 'check' {
		eprintln('unknown command "${os.args[1]}"')
		print_help()
		exit(2)
	}
	config_path, output_json := parse_check_args(os.args[2..]) or {
		eprintln('factory-doctor: ${err}')
		exit(2)
	}
	config := load_config(config_path) or {
		eprintln('factory-doctor: ${err}')
		exit(2)
	}
	report := run_checks(config)
	if output_json {
		println(json.encode(report))
	} else {
		print_report(report)
	}
	if report.status == 'fail' {
		exit(1)
	}
}

fn parse_check_args(args []string) !(string, bool) {
	mut config_path := 'factory-doctor.json'
	mut output_json := false
	mut index := 0
	for index < args.len {
		match args[index] {
			'--config', '-c' {
				if index + 1 >= args.len {
					return error('${args[index]} requires a path')
				}
				config_path = args[index + 1]
				index += 2
			}
			'--json' {
				output_json = true
				index++
			}
			else {
				return error('unknown option "${args[index]}"')
			}
		}
	}
	return config_path, output_json
}

fn run_bootstrap_command(args []string) int {
	if args.len > 0 && args[0] == 'init' {
		output_path, force := parse_bootstrap_init_args(args[1..]) or {
			eprintln('factory-doctor: ${err}')
			return 2
		}
		write_bootstrap_template(output_path, force) or {
			eprintln('factory-doctor: ${err}')
			return 2
		}
		println('wrote ${output_path}')
		return 0
	}
	profile_path, output_json, strict := parse_bootstrap_args(args) or {
		eprintln('factory-doctor: ${err}')
		return 2
	}
	profile := load_bootstrap_profile(profile_path) or {
		eprintln('factory-doctor: ${err}')
		return 2
	}
	report := run_bootstrap(profile)
	if output_json {
		println(json.encode(report))
	} else {
		print_bootstrap_report(report)
	}
	return bootstrap_exit_code(report, strict)
}

fn parse_bootstrap_args(args []string) !(string, bool, bool) {
	mut profile_path := 'factory-bootstrap.json'
	mut output_json := false
	mut strict := false
	mut index := 0
	for index < args.len {
		match args[index] {
			'--profile', '-p' {
				if index + 1 >= args.len {
					return error('${args[index]} requires a path')
				}
				profile_path = args[index + 1]
				index += 2
			}
			'--json' {
				output_json = true
				index++
			}
			'--strict' {
				strict = true
				index++
			}
			else {
				return error('unknown option "${args[index]}"')
			}
		}
	}
	return profile_path, output_json, strict
}

fn parse_bootstrap_init_args(args []string) !(string, bool) {
	mut output_path := 'factory-bootstrap.json'
	mut force := false
	mut index := 0
	for index < args.len {
		match args[index] {
			'--output', '-o' {
				if index + 1 >= args.len {
					return error('${args[index]} requires a path')
				}
				output_path = args[index + 1]
				index += 2
			}
			'--force' {
				force = true
				index++
			}
			else {
				return error('unknown option "${args[index]}"')
			}
		}
	}
	return output_path, force
}

fn print_report(report Report) {
	for check in report.checks {
		println('${check.status.to_upper():-4}  ${check.name} (${check.duration_ms} ms)  ${check.message}')
	}
	println('')
	println('${report.status.to_upper()}: ${report.summary.passed} passed, ${report.summary.warned} warned, ${report.summary.failed} failed')
}

fn print_help() {
	println('factory-doctor checks whether a software factory is ready before starting costly work.')
	println('')
	println('Usage:')
	println('  factory-doctor check [--config path] [--json]')
	println('  factory-doctor bootstrap [--profile path] [--json] [--strict]')
	println('  factory-doctor bootstrap init [--output path] [--force]')
	println('')
	println('Exit codes:')
	println('  0  All critical checks passed, or no required bootstrap item is missing')
	println('  1  A critical check failed, a required bootstrap item is missing, or --strict found open actions')
	println('  2  Invalid command, configuration, or bootstrap profile')
}
