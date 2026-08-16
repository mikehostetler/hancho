# Hancho Repository-Local Runtime State and Logs

Status: Early design idea

## Intent

Hancho needs one folder inside each local Git repository for durable operational state, logs, evidence, and recovery data.

This state belongs to the repository. It is not global user state. Hancho must not depend on an agent prompt, process memory, or temporary directory to recover a work order.

## Initial location

Store runtime data under the repository's Git common directory:

```text
<git-common-dir>/hancho/
```

For a normal checkout, this path appears as:

```text
.git/hancho/
```

Hancho must resolve the path with `git rev-parse --git-common-dir`. It must not assume that `.git` is a directory. A linked worktree can use a `.git` file that points to the common Git directory.

This location has three useful properties:

- Runtime data cannot enter a commit.
- All worktrees for one repository share the same runtime state.
- A different repository or clone has separate Hancho state.

An optional tracked `.hancho/` directory at the worktree root can hold workflow definitions, repository policy, and configuration. It must not hold runtime state or logs.

## Proposed layout

```text
<git-common-dir>/hancho/
├── hancho.sqlite3
├── repository.json
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

The Git common directory defines the local runtime boundary. One Hancho database serves one local repository and all of its worktrees.

The repository record can include:

- A generated Hancho repository ID.
- The normalized Git remote when one exists.
- The Git common-directory path.
- The current worktree paths as changeable bindings.

Moving a worktree must not create a new repository record. Creating a separate clone creates separate local Hancho state.

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
- Which artifacts can contain source code or sensitive application data?
- What are the default retention periods for completed, failed, and stopped runs?
- When should DuckDB or another reporting store read a snapshot of the operational data?
- Should Hancho support a controlled export and import when a repository is cloned again?
