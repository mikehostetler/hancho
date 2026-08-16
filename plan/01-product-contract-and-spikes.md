# Epic 01: Product Contract and Technical Spikes

## Goal

Fix the first product boundary and prove the technical choices that can block all later work.

## Depends on

None.

## Task 1.1: Write the Hancho domain contract

Define Factory Unit, Workflow, Station, Operator, Work Order, Journal, Action, Effect, Decision, and Andon. Define which component owns each fact and external effect.

Acceptance criteria:

- One document defines each term once.
- The document states that harnesses cannot commit, push, merge, release, deploy, or close work.
- The document states that commands send events and that the workflow engine selects transitions.
- The document gives one Build.V1 example from request to terminal result.

## Task 1.2: Define the first release boundary

Write the exact v0.1 commands, workflow, storage behavior, and non-goals.

Acceptance criteria:

- v0.1 includes `init`, `doctor`, `run`, `runs`, `show`, and `logs`.
- v0.1 uses one fake harness and does not need a network connection.
- v0.1 can recover the final state after the first process exits.
- The scope does not include tmux, GitHub writes, Beadwork writes, merge, release, or deployment.

## Task 1.3: Prove escript and OTP operation

Build a small supervised escript. Start one supervised process, stop it cleanly, and return a useful exit code.

Acceptance criteria:

- `MIX_ENV=prod mix escript.build` creates `./hancho`.
- The file runs from a temporary directory outside the source tree.
- `hancho version` and `hancho --help` work on the supported development system.
- A test proves that the supervision tree stops after both a normal exit and an interrupt.

## Task 1.4: Prove SQLite access from the escript

Compare a direct Elixir SQLite driver with the installed `sqlite3` executable. Select the smallest reliable option for the first supported systems.

Acceptance criteria:

- The built escript creates a database, runs a transaction, reads the data, and closes the database.
- The same test runs after the escript moves outside the source tree.
- The result records any Erlang runtime, native library, or operating-system requirement.
- An architecture decision records the selected driver and the rejected option.

## Task 1.5: Record reference-driver invariants

Convert `ralph_wiggum_loop_v2.sh` behavior into a parity checklist.

Acceptance criteria:

- The checklist covers Beadwork selection, dependency checks, allowed scope, gates, worktrees, harness limits, verification, bounded repairs, commit ownership, target-branch checks, receipts, push, and closure.
- Each item identifies the epic that will implement it.
- The checklist separates required parity from old LLMux-specific behavior.

## Epic exit criteria

- All architecture decisions are in the repository.
- The escript and SQLite proof passes on the main development system.
- No unresolved technical question blocks the Mix project foundation.
