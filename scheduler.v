module main

import time

const deadline_grace = 500 * time.millisecond

struct IndexedResult {
	index  int
	result CheckResult
}

// run_checks runs up to config.concurrency checks at once and returns results
// in configuration order. With a deadline_ms, each check's timeout is clipped
// to the time left, and checks that are still running or not yet started when
// the deadline passes are reported as skipped with code deadline_exceeded.
// The run returns at most deadline_grace after the deadline.
fn run_checks(config Config) Report {
	started := time.now()
	has_deadline := config.deadline_ms > 0
	deadline := started.add(config.deadline_ms * time.millisecond)
	// Workers clip timeouts to the deadline and mark late results as skipped.
	// The grace period lets them kill commands and report before the CLI exits.
	collect_until := deadline.add(deadline_grace)
	jobs := chan int{cap: config.checks.len}
	for index in 0 .. config.checks.len {
		jobs <- index
	}
	jobs.close()
	done := chan IndexedResult{cap: config.checks.len}
	workers := if config.concurrency < config.checks.len {
		config.concurrency
	} else {
		config.checks.len
	}
	for _ in 0 .. workers {
		spawn check_worker(config.checks, jobs, done, has_deadline, deadline)
	}
	mut results := []CheckResult{len: config.checks.len}
	mut received := []bool{len: config.checks.len}
	for _ in 0 .. config.checks.len {
		if !has_deadline {
			item := <-done
			results[item.index] = item.result
			received[item.index] = true
			continue
		}
		remaining := collect_until - time.now()
		if remaining <= 0 {
			break
		}
		mut timed_out := false
		select {
			item := <-done {
				results[item.index] = item.result
				received[item.index] = true
			}
			remaining {
				timed_out = true
			}
		}
		if timed_out {
			break
		}
	}
	for index, check in config.checks {
		if !received[index] {
			results[index] = skipped_result(check, started, deadline)
		}
	}
	mut report := build_report(results)
	return Report{
		...report
		duration_ms: time.since(started).milliseconds()
	}
}

fn check_worker(checks []CheckConfig, jobs chan int, done chan IndexedResult, has_deadline bool, deadline time.Time) {
	for {
		index := <-jobs or { break }
		check := checks[index]
		if !has_deadline {
			done <- IndexedResult{index, run_check(check)}
			continue
		}
		check_started := time.now()
		remaining := (deadline - check_started).milliseconds()
		if remaining <= 0 {
			done <- IndexedResult{index, skipped_result(check, check_started, deadline)}
			continue
		}
		clipped := if remaining < check.timeout_ms {
			CheckConfig{
				...check
				timeout_ms: int(remaining)
			}
		} else {
			check
		}
		result := run_check(clipped)
		done <- IndexedResult{index, if time.now() >= deadline {
			skipped_result(check, check_started, deadline)
		} else {
			result
		}}
	}
}

fn skipped_result(check CheckConfig, started time.Time, deadline time.Time) CheckResult {
	ran := deadline - started
	return CheckResult{
		name:        check.name
		kind:        check.kind
		target:      safe_target(check.kind, check.target)
		expect:      check.expect
		status:      'skipped'
		code:        'deadline_exceeded'
		message:     'deadline exceeded'
		duration_ms: if ran > 0 { ran.milliseconds() } else { 0 }
		critical:    check.critical
	}
}
