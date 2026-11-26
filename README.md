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
