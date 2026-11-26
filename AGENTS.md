# AGENTS.md

## Setup

Install the V version pinned in `.v-version` and put `v` on `PATH`.

## Commands

Run these before every commit. CI runs the same steps.

```sh
v fmt -verify .
v check-md README.md AGENTS.md
v -silent test .
v -prod -o factory-doctor .
```

Use `v fmt -w .` to fix formatting.

## Conventions

- The JSON report and exit codes (`0`, `1`, `2`) are a public contract. Do not
  rename fields or change exit codes without updating `README.md`.
- Every new check kind needs validation in `config.v`, a stable `code` string,
  and a test in `checks_test.v`.
- Run commands with literal arguments. Never invoke a shell.
- Never print credentials. Pass any target that can contain them through
  `safe_target`.
- Keep the tool vendor-neutral. Do not add provider-specific checks to the core.

## Traps

- Tests that need the network fail in sandboxes without egress. Keep unit
  tests offline and use `file` or `command` checks in test fixtures.
- `examples/factory-doctor.json` is user-facing documentation. Keep it valid.
