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
succeeds reports `unexpectedly_allowed` and fails the run when critical.

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

## Design principles

- Vendor-neutral checks and schemas.
- No credentials in output.
- Deterministic results and exit codes.
- Millisecond startup and a single native binary.
- Useful from a terminal, CI step, agent hook, or local MCP server.

## License

MIT
