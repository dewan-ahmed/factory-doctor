module main

import json2
import os

fn main() {
	if os.args.len < 2 || os.args[1] in ['help', '--help', '-h'] {
		print_help()
		return
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
		println(json2.encode[Report](report))
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
	println('')
	println('Exit codes:')
	println('  0  All critical checks passed')
	println('  1  One or more critical checks failed')
	println('  2  Invalid command or configuration')
}
