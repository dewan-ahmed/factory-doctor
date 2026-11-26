module main

pub struct Config {
pub:
	version int = 1
	checks  []CheckConfig
}

pub struct CheckConfig {
pub:
	name              string
	kind              string
	target            string
	args              []string
	expect_status     int    = 200
	timeout_ms        int    = 3_000
	critical          bool   = true
	expect            string = 'pass'
	working_directory string
	max_files         int
	max_lines         int
	exclude           []string
}

pub struct CheckResult {
pub:
	name        string
	kind        string
	target      string
	expect      string
	status      string
	code        string
	message     string
	duration_ms i64
}

pub struct Summary {
pub:
	total  int
	passed int
	warned int
	failed int
}

pub struct Report {
pub:
	version int = 1
	status  string
	checks  []CheckResult
	summary Summary
}
