# Hancho Repository-Local Folder, State, and Logs

Status: Early design idea

## Intent

Hancho needs one ignored `.hancho/` folder at the target repository root. This folder holds local machine configuration, custom harness adapters, durable operational state, logs, evidence, and recovery data.

This state belongs to the repository. It is not global user state. Hancho must not depend on an agent prompt, process memory, or temporary directory to recover a work order.

## Location and Git rule

Use this path:

```text
<repository-root>/.hancho/
```

Add this rule to the repository `.gitignore`:

```gitignore
# Hancho local configuration and runtime data
.hancho/
```

The whole folder is local and untracked. It can contain machine paths and harness choices that do not apply to another developer or machine.

This location has three useful properties:

- Configuration and runtime data stay together.
- Git status stays clean while Hancho operates.
- Each checkout can use different installed CLI harnesses and local paths.

Hancho-created execution worktrees do not create a second control folder. They use the configuration and runtime state from the checkout that started the work order.

## Proposed layout

```text
<repository-root>/.hancho/
├── config.toml
├── hancho.sqlite3
├── repository.json
├── factory.json
├── control.sock
├── harnesses/
│   └── pi
├── runs/
│   └── <run-id>/
│       ├── run.json
│       ├── events.jsonl
│       ├── prompts/
│       ├── logs/
│       ├── checks/
│       ├── artifacts/
│       └── receipts/
├── locks/
└── tmp/
```

The configuration selects workflows, CLI harnesses, adapter executables, capabilities, and station routing. The database stores indexed operational facts. `factory.json` identifies the active process host. `control.sock` carries commands to a running factory. Files store large or stream-oriented artifacts. The database records each artifact path, content hash, size, creation time, and retention class.

See [Hancho CLI harness adapters and routing](hancho-cli-harnesses.md) for the configuration concept.

## Initial database choice

Prefer **SQLite** for the first operational store.

SQLite fits this use because it provides a portable single-file database, transactions, process-level locking, and recovery after an incomplete transaction.

Do not use DuckDB as the primary operational store in the first version. DuckDB is designed mainly for analytical workloads. Its native read-write concurrency is centered on one process. DuckDB can become an optional analytics tool for flow, quality, cost, and cycle-time reports.

References:

- [SQLite single-file database](https://www.sqlite.org/onefile.html)
- [SQLite transactions](https://www.sqlite.org/lang_transaction.html)
- [SQLite file format and recovery journal](https://www.sqlite.org/fileformat.html)
- [Why DuckDB](https://duckdb.org/why_duckdb)
- [DuckDB concurrency](https://duckdb.org/docs/current/connect/concurrency)

## Database responsibilities

The initial schema can include:

- The local repository identity and worktree bindings.
- Workflow names and pinned versions.
- Work orders and current states.
- Append-only transition events.
- Requested, started, completed, failed, and uncertain actions.
- External-effect intents and observed results.
- Harness sessions and versions.
- Human decisions and approvals.
- Evidence and artifact indexes.
- Leases or locks for active work.

Do not store large command output, harness streams, or generated reports as database values. Store these artifacts as files and index them in SQLite.

## Repository identity

The control checkout root defines the local runtime boundary. One Hancho database serves the Hancho runs that start from that checkout.

The repository record can include:

- A generated Hancho repository ID.
- The normalized Git remote when one exists.
- The control checkout path.
- The Git common-directory path.
- Execution worktree paths as changeable bindings.

Creating a separate clone creates separate local Hancho configuration and state.

## Durability and recovery rules

- Record a transition before Hancho starts the next station.
- Record an external-effect intent before commit, push, pull request, release, or deployment actions.
- Record the observed result after the effect.
- Treat a crash between intent and result as an uncertain effect.
- Reconcile the actual external state before a retry.
- Pin the workflow name and version for every work order.
- Keep the current-state view and the append-only event journal consistent in one database transaction.
- Keep raw logs useful for evidence, but do not make them the source of truth for workflow state.

These rules support `hancho status`, `hancho resume`, and `hancho reconcile` after a process or machine failure.

## Security and retention

- Restrict the repository runtime directory and database to the current user.
- Redact secrets from harness and command logs before persistence when possible.
- Do not copy full environment values into the database or logs.
- Give prompts, raw output, checks, receipts, and reports separate retention classes.
- Keep durable decisions and transition facts longer than raw diagnostic logs.
- Make cleanup visible and recoverable. Provide a dry-run view before deletion.

## Open questions

- Should `events.jsonl` duplicate database events for direct inspection, or should SQLite be the only event store?
- How should a user share a useful local harness configuration without committing machine-specific details?
- How should Hancho behave when it starts from a linked Git worktree?
- Which artifacts can contain source code or sensitive application data?
- What are the default retention periods for completed, failed, and stopped runs?
- When should DuckDB or another reporting store read a snapshot of the operational data?
- Should Hancho support a controlled export and import when a repository is cloned again?
