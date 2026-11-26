module main

import os
import time

fn sleep_check(name string, seconds string, critical bool) CheckConfig {
	return CheckConfig{
		name:       name
		kind:       'command'
		target:     'sleep'
		args:       [seconds]
		timeout_ms: 10_000
		critical:   critical
	}
}

fn test_results_keep_config_order_when_run_concurrently() {
	report := run_checks(Config{
		concurrency: 3
		checks:      [sleep_check('slow', '0.4', true), sleep_check('medium', '0.2', true),
			sleep_check('fast', '0', true)]
	})
	assert report.checks.map(it.name) == ['slow', 'medium', 'fast']
	assert report.status == 'pass'
	assert report.duration_ms < 1_000, 'checks did not run concurrently'
}

fn test_concurrency_one_runs_sequentially() {
	report := run_checks(Config{
		concurrency: 1
		checks:      [sleep_check('a', '0.2', true), sleep_check('b', '0.2', true)]
	})
	assert report.duration_ms >= 400
}

fn test_deadline_skips_running_and_pending_checks_and_kills_process() {
	marker := '7.31'
	started := time.now()
	report := run_checks(Config{
		concurrency: 1
		deadline_ms: 300
		checks:      [sleep_check('fast', '0', true), sleep_check('slow', marker, true),
			sleep_check('never started', '0', false)]
	})
	assert time.since(started).milliseconds() < 2_000
	assert report.checks.map(it.name) == ['fast', 'slow', 'never started']
	assert report.checks[0].status == 'pass'
	assert report.checks[1].status == 'skipped'
	assert report.checks[1].code == 'deadline_exceeded'
	assert report.checks[2].status == 'skipped'
	assert report.summary.skipped == 2
	assert report.status == 'fail'
	pgrep := os.execute('pgrep -f "[s]leep ${marker}"')
	assert pgrep.exit_code != 0, 'sleep process was not killed: ${pgrep.output}'
}

fn test_skipped_non_critical_check_only_warns() {
	report := build_report([
		CheckResult{
			status: 'pass'
		},
		CheckResult{
			status:   'skipped'
			critical: false
		},
	])
	assert report.status == 'warn'
	assert report.summary.skipped == 1
}

fn test_parse_check_args_reads_scheduling_flags() {
	options := parse_check_args(['--concurrency', '8', '--deadline-ms', '15000', '--json'])!
	assert options.concurrency == 8
	assert options.deadline_ms == 15_000
	assert options.output_json
	defaults := parse_check_args([])!
	assert defaults.concurrency == 0
	assert defaults.deadline_ms == -1
	for bad in [['--concurrency', '0'], ['--concurrency', 'x'],
		['--deadline-ms', '-5'], ['--deadline-ms']] {
		if _ := parse_check_args(bad) {
			assert false, 'expected ${bad} to be rejected'
		}
	}
}

fn test_validate_config_rejects_bad_scheduling_fields() {
	for config in [
		Config{
			concurrency: 0
			checks:      [sleep_check('a', '0', true)]
		},
		Config{
			deadline_ms: -1
			checks:      [sleep_check('a', '0', true)]
		},
	] {
		if _ := validate_config(config) {
			assert false, 'expected validation error'
		}
	}
}

fn test_result_published_before_deadline_is_kept() {
	report := run_checks(Config{
		concurrency: 2
		deadline_ms: 400
		checks:      [sleep_check('finishes in time', '0.35', true),
			sleep_check('too slow', '5', false)]
	})
	assert report.checks[0].status == 'pass'
	assert report.checks[1].status == 'skipped'
	assert report.status == 'warn'
}
