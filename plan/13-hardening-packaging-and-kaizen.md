# Epic 13: Hardening, Packaging, and Kaizen

## Goal

Make Hancho safe to install, operate, measure, and use as the replacement for the Bash driver.

## Depends on

Epics 01-12.

## Task 13.1: Add security and redaction controls

Protect local state, environment data, prompts, source artifacts, and process output.

Acceptance criteria:

- New `./.hancho/` content uses current-user permissions where supported.
- Logs never persist a full environment map.
- Configured secret patterns and known tokens are redacted before normal log persistence.
- Raw sensitive artifacts have an explicit warning and retention class.
- Tests cover path traversal, command argument boundaries, and hostile adapter output.

## Task 13.2: Add retention and cleanup

Define separate retention for durable events, raw logs, prompts, checks, reports, and temporary worktrees.

Acceptance criteria:

- Cleanup has a dry-run view by default.
- Cleanup cannot remove active or uncertain work-order evidence.
- Each removed artifact produces an audit record.
- Database compaction does not change durable transition facts.

## Task 13.3: Add reliability and compatibility tests

Test supported Elixir, Erlang, Git, SQLite, tmux, and operating-system combinations.

Acceptance criteria:

- Tests cover normal exit, interrupt, forced stop, full disk, process timeout, malformed adapter output, and database lock contention.
- A long-run test processes several work orders with the configured WIP limit.
- Fixtures cover an Elixir library and a Phoenix application.
- Network and real-model tests are optional and separate from the default suite.

## Task 13.4: Package and install the escript

Document the supported runtime and provide a repeatable build, checksum, install, upgrade, and rollback process.

Acceptance criteria:

- A clean checkout builds one `hancho` escript with a version.
- The installed file runs outside the source repository.
- `hancho doctor` identifies an incompatible Erlang runtime or missing native dependency.
- Upgrade notes state whether the local database needs migration.
- A failed upgrade can restore the prior escript and open the prior compatible state.

## Task 13.5: Reach Bash-driver parity and retire it

Run the parity checklist from Epic 01 against Build.V1. Keep the script until every required item passes.

Acceptance criteria:

- Each required parity item has an automated test or a documented manual proof.
- At least one real repository work order completes with Hancho and with no direct script use.
- The migration guide maps old flags and files to Hancho commands and state.
- The Bash driver becomes a marked reference file before any later removal decision.

## Task 13.6: Add factory measures and Kaizen records

Calculate flow and quality measures from journal facts. Do not use them to rank people or reward code volume.

Acceptance criteria:

- Reports include oldest committed age, active WIP, start-to-merge time, blocked time, rework count, review wait, failed delivery count, and Andon causes.
- Every measure defines its event source and calculation.
- A standard-work change has a proposal, expected result, version, approval, and later evaluation.
- Active work orders stay pinned to their original workflow version.

## Epic exit criteria

- Hancho is the documented default local factory driver.
- The escript has a repeatable install path, safe state migrations, recovery tests, and an operating guide.
- Measures can support workflow improvement without changing historical records.
