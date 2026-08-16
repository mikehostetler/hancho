# Epic 05: Durable State, Journal, and Artifacts

## Goal

Make each work order recoverable after a command, process, or machine stops.

## Depends on

Epics 01, 03, and 04.

## Task 5.1: Add database migrations

Create schema versioning and the initial SQLite tables for repositories, workflows, work orders, events, actions, effects, decisions, harness sessions, artifacts, and leases.

Acceptance criteria:

- A new database migrates to the current schema in one command.
- A second migration run makes no changes.
- An unknown newer schema version stops startup without changing the database.
- A failed migration rolls back and leaves a usable prior schema.

## Task 5.2: Implement the append-only journal

Store actor, UTC time, run ID, prior state, event, result state, reason, and correlation ID for each transition.

Acceptance criteria:

- The current-state view and event append occur in one transaction.
- Event rows cannot be updated through the journal interface.
- Each event has a stable sequence number inside its work order.
- Replaying the events produces the stored current state.

## Task 5.3: Implement action and effect records

Record requested, started, completed, failed, and uncertain actions. Record intent before a Git, Beadwork, or other external effect.

Acceptance criteria:

- An action cannot complete before it starts.
- A crash simulation after effect intent leaves an `uncertain` effect at restart.
- Hancho does not retry an uncertain effect without a successful reconciliation event.
- Idempotency keys are stable across recovery attempts.

## Task 5.4: Implement run artifact storage

Create run folders and store prompts, raw logs, checks, reports, and receipts as files.

Acceptance criteria:

- Every artifact record contains a relative path, content hash, byte size, creation time, media type, and retention class.
- Hancho rejects a path that escapes the work-order artifact folder.
- A missing or changed file is visible during evidence validation.
- Large process output does not enter a database value.

## Task 5.5: Add read models

Provide queries for recent runs, one run, open decisions, active actions, Andon stops, and uncertain effects.

Acceptance criteria:

- Queries return stable ordering.
- Read operations work when no factory process is active.
- Human and JSON views use the same query results.
- A database fixture with an interrupted run shows the correct recovery state.

## Epic exit criteria

- The walking-skeleton run can stop, restart, and show the same terminal or stopped state.
- Journal replay and the current-state view agree for all tests.
