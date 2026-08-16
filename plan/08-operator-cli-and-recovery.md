# Epic 08: Operator CLI, Decisions, and Recovery

## Goal

Give the user a complete one-work-order operating interface before Hancho becomes a continuous factory.

## Depends on

Epics 05, 06, and 07.

## Task 8.1: Implement work-order commands

Add `hancho run WORKFLOW WORK_REF`, `hancho runs`, and `hancho show RUN_ID`.

Acceptance criteria:

- `run` follows the work order to a terminal state, a decision request, or an Andon stop.
- One-work-order mode stays in the foreground. It does not leave an unmanaged child process.
- `runs` shows active and recent work in stable order.
- `show` includes state, workflow version, station, evidence, decisions, effects, and the likely next command.

## Task 8.2: Implement event and raw log views

Add `hancho logs` with run, station, time, follow, and raw-output options.

Acceptance criteria:

- The default view shows normalized journal events, not raw model output.
- `--raw` identifies the exact artifact and warns when it can contain sensitive source data.
- `--follow` ends when a foreground work order reaches a stop or terminal result.
- JSON log output preserves stable event fields.

## Task 8.3: Implement durable decisions

Add `hancho decisions`, `hancho approve`, and `hancho reject`.

Acceptance criteria:

- A background or detached command never waits on an interactive prompt.
- Approval and rejection require a reason and record the actor.
- A decision command sends an event and cannot force an arbitrary target state.
- A second answer to a closed decision is idempotent or returns a clear conflict.

## Task 8.4: Implement cancel and resume

Add `hancho cancel RUN_ID --reason TEXT` and `hancho resume RUN_ID`.

Acceptance criteria:

- Cancel requests a safe boundary before it uses a forced process stop.
- Resume works only from a permitted stopped or interrupted state.
- Neither command discards logs, worktrees, or evidence.
- Repeated commands do not create duplicate state transitions.

## Task 8.5: Implement effect reconciliation

Add `hancho reconcile RUN_ID` for uncertain Git and work-item effects.

Acceptance criteria:

- Reconcile reads actual external state before it writes a result event.
- A confirmed effect does not run again.
- A confirmed absence makes a policy-permitted retry possible.
- An ambiguous result stays uncertain and gives a human next action.

## Task 8.6: Define exit codes and JSON schemas

Use stable machine contracts for success, input error, configuration error, stopped work, decision needed, and internal failure.

Acceptance criteria:

- The command reference lists every exit code.
- Human and JSON output agree on result type and stable IDs.
- Expected errors have no Elixir stack trace unless debug mode is active.
- Contract tests cover every public command.

## Epic exit criteria

- A user can start, inspect, stop, decide, recover, and reconcile one Build.V1 run.
- No recovery action needs manual SQLite edits.
