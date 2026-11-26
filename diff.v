module main

import os
import time

struct DiffStat {
	path    string
	changed int
}

// check_diff fails when the change against check.target (a base ref) is too
// large to review. It compares the merge base with the working tree, so
// uncommitted tracked changes count too.
fn check_diff(check CheckConfig) Outcome {
	output := capture_command(check, 'git', ['-c', 'core.quotepath=off', 'diff', '--numstat',
		'--merge-base', check.target]) or {
		return Outcome{
			code:    err.msg().all_before(':')
			message: err.msg().all_after(': ')
		}
	}
	mut stats := []DiffStat{}
	mut lines := 0
	for row in output.split_into_lines() {
		parts := row.split('\t')
		if parts.len < 3 || parts[0] == '-' {
			continue
		}
		path := parts[2..].join('\t')
		if check.exclude.any(glob_match(it, path)
			|| (!it.contains('/') && glob_match(it, os.base(path))))
		{
			continue
		}
		changed := parts[0].int() + parts[1].int()
		stats << DiffStat{path, changed}
		lines += changed
	}
	summary := '${stats.len} files, ${lines} lines changed against ${check.target}'
	over_files := check.max_files > 0 && stats.len > check.max_files
	over_lines := check.max_lines > 0 && lines > check.max_lines
	if !over_files && !over_lines {
		return Outcome{
			passed:  true
			code:    'ok'
			message: summary
		}
	}
	stats.sort(a.changed > b.changed)
	largest := stats[..if stats.len > 3 { 3 } else { stats.len }].map('${it.path} (${it.changed})')
	return Outcome{
		code:    'diff_too_large'
		message: '${summary}; limits ${check.max_files} files, ${check.max_lines} lines; largest: ${largest.join(', ')}'
	}
}

// capture_command runs executable with literal arguments and returns stdout.
// Errors are formatted as "code: message".
fn capture_command(check CheckConfig, executable string, args []string) !string {
	path := os.find_abs_path_of_executable(executable) or {
		return error('executable_not_found: executable "${executable}" was not found')
	}
	if check.working_directory != '' && !os.is_dir(check.working_directory) {
		return error('working_directory_not_found: working directory does not exist')
	}
	mut process := os.new_process(path)
	process.set_args(args)
	process.use_pgroup = true
	if check.working_directory != '' {
		process.set_work_folder(check.working_directory)
	}
	process.set_redirect_stdio()
	process.run()
	started := time.now()
	mut output := []string{}
	for process.is_alive() {
		if process.is_pending(.stdout) {
			output << process.stdout_read()
		}
		if process.is_pending(.stderr) {
			process.stderr_read()
		}
		if time.since(started).milliseconds() >= check.timeout_ms {
			process.signal_pgkill()
			process.wait()
			process.close()
			return error('command_timeout: timed out after ${check.timeout_ms} ms')
		}
		time.sleep(5 * time.millisecond)
	}
	process.wait()
	output << process.stdout_slurp()
	exit_code := process.code
	process.close()
	if exit_code != 0 {
		return error('command_failed: git diff exit code ${exit_code}')
	}
	return output.join('')
}

// glob_match supports `*` (within one path segment), `**` (any depth), and `?`.
fn glob_match(pattern string, path string) bool {
	if pattern == '' {
		return path == ''
	}
	if pattern.starts_with('**') {
		rest := pattern[2..].trim_left('/')
		for i in 0 .. path.len + 1 {
			if glob_match(rest, path[i..]) {
				return true
			}
		}
		return false
	}
	if path == '' {
		return false
	}
	return match pattern[0] {
		`*` {
			for i in 0 .. path.len + 1 {
				if i > 0 && path[i - 1] == `/` {
					break
				}
				if glob_match(pattern[1..], path[i..]) {
					return true
				}
			}
			false
		}
		`?` {
			path[0] != `/` && glob_match(pattern[1..], path[1..])
		}
		else {
			pattern[0] == path[0] && glob_match(pattern[1..], path[1..])
		}
	}
}
