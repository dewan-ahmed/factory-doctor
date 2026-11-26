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
	output := capture_command(check, 'git', ['diff', '--numstat', '-z', '--no-relative',
		'--merge-base', check.target]) or {
		return Outcome{
			code:    err.msg().all_before(':')
			message: err.msg().all_after(': ')
		}
	}
	mut stats := []DiffStat{}
	mut lines := 0
	for entry in parse_numstat(output) {
		if entry.binary || check.exclude.any(diff_excluded(it, entry.paths)) {
			continue
		}
		stats << DiffStat{entry.paths.last(), entry.changed}
		lines += entry.changed
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
	largest :=
		stats[..if stats.len > 3 { 3 } else { stats.len }].map('${printable(it.path)} (${it.changed})')
	return Outcome{
		code:    'diff_too_large'
		message: '${summary}; limits ${check.max_files} files, ${check.max_lines} lines; largest: ${largest.join(', ')}'
	}
}

// printable replaces control characters so a file name cannot rewrite the
// terminal report.
fn printable(value string) string {
	return value.bytes().map(if it < 0x20 || it == 0x7f { u8(`?`) } else { it }).bytestr()
}

struct NumstatEntry {
	paths   []string
	changed int
	binary  bool
}

// parse_numstat reads `git diff --numstat -z`. A rename is
// `added\tdeleted\t\0old\0new\0`; other entries are `added\tdeleted\tpath\0`.
fn parse_numstat(output string) []NumstatEntry {
	tokens := output.split('\0')
	mut entries := []NumstatEntry{}
	mut index := 0
	for index < tokens.len {
		parts := tokens[index].split('\t')
		index++
		if parts.len < 3 {
			continue
		}
		mut paths := [parts[2..].join('\t')]
		if paths[0] == '' && index + 1 < tokens.len {
			paths = [tokens[index], tokens[index + 1]]
			index += 2
		}
		entries << NumstatEntry{
			paths:   paths
			changed: parts[0].int() + parts[1].int()
			binary:  parts[0] == '-'
		}
	}
	return entries
}

// diff_excluded matches a pattern against every path of an entry, so a renamed
// file is excluded when either its old or new path is.
fn diff_excluded(pattern string, paths []string) bool {
	return paths.any(glob_match(pattern, it)
		|| (!pattern.contains('/') && glob_match(pattern, os.base(it))))
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
		at_boundary := pattern.len > 2 && pattern[2] == `/`
		for i in 0 .. path.len + 1 {
			if at_boundary && i > 0 && path[i - 1] != `/` {
				continue
			}
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
