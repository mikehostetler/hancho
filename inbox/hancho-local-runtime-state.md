# Hancho Local Runtime State and Logs

Status: Early design idea

## Intent

Hancho needs one local folder for durable operational state, logs, evidence, and recovery data.

This folder stays outside target repository worktrees. Hancho must not depend on an agent prompt, process memory, or temporary directory to recover a work order.

## Initial location

Use one configurable data root.

- Environment override: `HANCHO_HOME`.
- Initial default candidate: `~/.hancho/`.
- Review platform-specific and XDG locations before the first public release.

The path is a design candidate. It is not yet a stable interface.

## Proposed layout

```text
~/.hancho/
├── hancho.sqlite3
├── projects/
│   └── <project-id>/
│       ├── project.json
│       └── runs/
│           └── <run-id>/
│               ├── run.json
│               ├── events.jsonl
│               ├── prompts/
│               ├── logs/
│               ├── checks/
│               ├── artifacts/
│               └── receipts/
├── locks/
└── tmp/
```

The database stores indexed operational facts. Files store large or stream-oriented artifacts. The database records each file path, content hash, size, creation time, and retention class.

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

- Projects and repository identities.
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

## Project identity

Do not use only the current checkout path as the project identity. A repository can move.

The project record can use:

- A generated Hancho project ID.
- The normalized Git remote when one exists.
- The Git common-directory identity.
- The current local paths as changeable bindings.

One repository can have several worktrees. All worktrees must resolve to the same Hancho project record.

## Durability and recovery rules

- Record a transition before Hancho starts the next station.
- Record an external-effect intent before commit, push, pull-request, release, or deployment actions.
- Record the observed result after the effect.
- Treat a crash between intent and result as an uncertain effect.
- Reconcile the actual external state before a retry.
- Pin the workflow name and version for every work order.
- Keep the current-state view and the append-only event journal consistent in one database transaction.
- Keep raw logs useful for evidence, but do not make them the source of truth for workflow state.

These rules support `hancho status`, `hancho resume`, and `hancho reconcile` after a process or machine failure.

## Security and retention

- Restrict the data root and database to the current user.
- Redact secrets from harness and command logs before persistence when possible.
- Do not copy full environment values into the database or logs.
- Give prompts, raw output, checks, receipts, and reports separate retention classes.
- Keep durable decisions and transition facts longer than raw diagnostic logs.
- Make cleanup visible and recoverable. Provide a dry-run view before deletion.

## Open questions

- Should Hancho use one global database or one database per project?
- Should `events.jsonl` duplicate database events for direct inspection, or should SQLite be the only event store?
- How should Hancho identify repositories that have no remote?
- Which artifacts can contain source code or sensitive application data?
- What are the default retention periods for completed, failed, and stopped runs?
- When should DuckDB or another reporting store read a snapshot of the operational data?
