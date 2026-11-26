# factory-doctor

Fast, deterministic preflight checks for AI agents and software factories.

`factory-doctor` catches missing tools, unreachable services, broken repository
access, and unavailable files before a factory starts an expensive agent or
compute session. It is vendor-neutral, runs locally, and emits stable JSON for
automation.

## Status

Early development. The configuration and output schema can change before
version 1.0.

## Checks

- `http`: require an endpoint to return an expected status.
- `command`: run a command with literal arguments and a timeout.
- `git_remote`: confirm a Git remote and optional ref are accessible.
- `file`: confirm a local file or directory is readable.
- `env`: confirm an environment variable is set without printing its value.
- `tcp`: open a TCP connection to `host:port`, then close it without sending
  data.
- `dns`: confirm a hostname resolves to at least one address.
- `diff`: fail when the change against a base ref is too large to review.
  `target` is the base ref, and at least one of `max_files` or `max_lines`
  (added plus deleted) is required. The check compares the merge base with
  the working tree, so uncommitted tracked changes count too. Binary files
  and `exclude` globs (`*.lock`, `testdata/**`) are skipped. A failure has
  code `diff_too_large` and names the three largest files, so an agent knows
  what to split before it opens a PR:

  ```json
  {"name": "reviewable-change", "kind": "diff", "target": "origin/main",
   "max_files": 20, "max_lines": 400, "exclude": ["*.lock"]}
  ```

Checks marked `"critical": false` produce warnings instead of a failing exit
code.

Checks marked `"expect": "fail"` pass only when the underlying check fails.
Use them to prove that a sandbox or CI runner blocks access it should not
have, such as host credentials or unapproved network egress:

```json
{
  "name": "Host SSH keys are hidden",
  "kind": "file",
  "target": "/home/agent/.ssh",
  "expect": "fail"
}
```

A denied check reports `blocked_as_expected`. A check that unexpectedly
succeeds reports `unexpectedly_allowed` and fails the run when critical. For
`http`, any response counts as allowed, whatever its status.

Only failures that show denial count: `file_not_found` or `file_not_readable`
for `file`, `http_request_failed` for `http`, a failed or timed-out command for
`command` and `git_remote`, and a missing executable for `command`. Anything
else, such as `git` not being installed for a `git_remote` check, reports
`inconclusive_denial` and is treated as a failure.

## Build

Install the V version in `.v-version`, then run:

```sh
v -prod -o factory-doctor .
```

## Use

```sh
cp examples/factory-doctor.json factory-doctor.json
./factory-doctor check
./factory-doctor check --config factory-doctor.json --json
```

Exit codes are stable:

- `0`: all critical checks passed.
- `1`: at least one critical check failed.
- `2`: invalid arguments or configuration.

## Network checks

`tcp` and `dns` checks catch firewall, egress allowlist, private DNS zone, and
VPN problems for dependencies that do not speak HTTP, such as databases,
caches, brokers, and SSH Git hosts. They use the standard library and need no
`nc`, `dig`, or `nslookup` on the runner.

```json
[
  {
    "name": "Postgres reachable",
    "kind": "tcp",
    "target": "db.internal.example.com:5432",
    "timeout_ms": 2000
  },
  {
    "name": "Internal registry resolves",
    "kind": "dns",
    "target": "registry.internal.example.com",
    "args": ["ipv4"],
    "timeout_ms": 1000
  }
]
```

A `tcp` target must include a port. Wrap IPv6 literals in brackets, as in
`[::1]:5432`. Configuration validation rejects other forms with exit code `2`.
A `dns` check can list required address families, `ipv4` or `ipv6`, in `args`.

Failure codes are `dns_resolution_failed`, `tcp_connect_refused`,
`tcp_connect_timeout`, `tcp_connect_failed` (for example, network unreachable),
`dns_family_missing`, and `invalid_target`. With `"expect": "fail"`, a
resolution failure, refusal, timeout, or connect failure counts as denied. A
missing address family is inconclusive, because the name still resolved.

## Configuration

```json
{
  "version": 1,
  "checks": [
    {
      "name": "Source repository",
      "kind": "git_remote",
      "target": "https://github.com/example/project",
      "args": ["HEAD"],
      "timeout_ms": 5000
    },
    {
      "name": "Factory API",
      "kind": "http",
      "target": "https://factory.example.com/health",
      "expect_status": 200,
      "timeout_ms": 3000
    }
  ]
}
```

Command arguments are passed literally without a shell. Do not put credentials
in configuration files. Use the target tool's environment or workload identity
support.

## Time budget

Checks run one at a time by default. To run several at once and put a hard
upper bound on the whole run, set `concurrency` and `deadline_ms` at the top
level of the config, or pass `--concurrency N` and `--deadline-ms N`. Flags win
over the config file.

```json
{
  "version": 1,
  "concurrency": 8,
  "deadline_ms": 15000,
  "checks": []
}
```

Results keep configuration order whatever order checks finish in. When the
deadline passes, each check's `timeout_ms` is clipped to the time left, running
commands are killed with their process group, and checks that are still
running or never started report status `skipped` with code
`deadline_exceeded`. A skipped critical check fails the run, and a skipped
non-critical check warns. The run returns at most 500 ms after the deadline,
which gives killed commands time to exit. Exit codes do not change.

The JSON report adds `duration_ms` for the whole run, `critical` on each check,
and `skipped` in `summary`:

```json
{
  "version": 1,
  "status": "fail",
  "duration_ms": 15004,
  "checks": [
    {
      "name": "Internal API",
      "kind": "http",
      "target": "https://api.internal.example.com/health",
      "expect": "pass",
      "status": "skipped",
      "code": "deadline_exceeded",
      "message": "deadline exceeded",
      "duration_ms": 15000,
      "critical": true
    }
  ],
  "summary": { "total": 1, "passed": 0, "warned": 0, "failed": 0, "skipped": 1 }
}
```

## Bootstrap readiness

`factory-doctor bootstrap` checks whether a new software factory has the setup
agents need before the first session: identities, secrets, source control,
connectors, environments, network access, agent instructions, model defaults,
budgets, audit trails, and review policy.

```sh
./factory-doctor bootstrap init
./factory-doctor bootstrap
./factory-doctor bootstrap --profile factory-bootstrap.json --json
./factory-doctor bootstrap --strict
```

`bootstrap init` writes a starter profile from
`examples/factory-bootstrap.json` to `factory-bootstrap.json`. It refuses to
replace an existing file unless `--force` is set. Edit the profile for your
factory, then commit it with your environment setup.

Each requirement has a category, a reason, next-step guidance, and a `verify`
method. Automated methods reuse the check kinds above. `manual` requirements
cannot be verified locally; set `"confirmed": true` once the team has completed
them.

```json
{
  "version": 1,
  "name": "Platform factory",
  "requirements": [
    {
      "id": "secrets.source-control-token",
      "category": "secrets",
      "name": "Source control token",
      "rationale": "Agents need repository access without stored credentials.",
      "guidance": "Expose a least-privilege token as SOURCE_CONTROL_TOKEN.",
      "verify": { "kind": "env", "target": "SOURCE_CONTROL_TOKEN" }
    },
    {
      "id": "budgets.spend-limits",
      "category": "budgets",
      "name": "Spend limits and alerts",
      "guidance": "Set per-session or per-team limits and alerts.",
      "verify": { "kind": "manual" },
      "confirmed": true
    }
  ]
}
```

Supported categories are `identity`, `secrets`, `source_control`,
`connectors`, `environments`, `network`, `agents`, `models`, `budgets`,
`observability`, and `policy`. Requirements are required by default; set
`"required": false` for recommendations.

Results are `pass`, `missing`, `warn`, or `manual`. The overall status is
`ready`, `action_required`, or `not_ready`. Bootstrap exits `1` when a required
item is missing, and with `--strict` also when any warning or manual item is
open. Invalid profiles exit `2`.

The profile describes capabilities, not vendor setup. It does not create
accounts, store credentials, or change factory settings. Vendor-specific setup
steps belong in each requirement's `guidance` and `docs_url`.

## Design principles

- Vendor-neutral checks and schemas.
- No credentials in output.
- Deterministic results and exit codes.
- Millisecond startup and a single native binary.
- Useful from a terminal, CI step, agent hook, or local MCP server.

## License

MIT
