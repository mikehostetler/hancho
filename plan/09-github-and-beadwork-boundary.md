# Epic 09: GitHub and Beadwork Boundary

## Goal

Connect work orders to the correct commitment and execution records without creating two task systems inside Hancho.

## Depends on

Epics 05 and 08.

## Task 9.1: Fix the work-reference policy

Answer the open policy questions for link format, Beadwork threshold, closure order, final summary location, and derived GitHub labels.

Acceptance criteria:

- One policy defines the canonical GitHub Issue and root Beadwork link fields.
- The policy states when work is small enough to run without a Beadwork item.
- The policy defines what closes before merge, after merge, and after delivery.
- The policy forbids automatic two-way task-list sync.

## Task 9.2: Define work-reference data

Store an optional GitHub Issue reference, an optional Beadwork root reference, discovered child work, and acceptance conditions on each work order.

Acceptance criteria:

- At least one accepted work reference is required for a Build.V1 run.
- A root Beadwork item can link to only one canonical GitHub Issue in the initial policy.
- Material scope changes create a decision request instead of changing the stored commitment.
- Work-reference data remains available after local external tools are unavailable.

## Task 9.3: Implement the Beadwork adapter

Use the `bw` CLI to list ready tasks, inspect dependencies, claim work, add execution links, and close work.

Acceptance criteria:

- Hancho skips an item with an open blocker unless explicit policy permits it.
- Claim and closure use effect intent, observed result, and reconciliation.
- A failed `bw sync` is visible and does not erase the local result.
- Contract tests use a fake `bw` executable and do not change the user's Beadwork data.

## Task 9.4: Implement the GitHub Issue adapter

Use the `gh` CLI to validate the issue, read accepted scope, and post only configured material events.

Acceptance criteria:

- Read-only mode can validate a repository and issue without writing a comment.
- Routine harness progress does not enter the issue.
- Scope changes, owner decisions, blockers, and final delivery can be posted as separate effect types.
- A GitHub failure cannot change Beadwork or workflow state without an explicit result event.

## Task 9.5: Implement ready-work selection

Select ready Beadwork tasks in a stable order and enforce dependencies, WIP policy, explicit ranges, and dry-run views.

Acceptance criteria:

- `--only`, `--max`, and dry-run selection have deterministic results.
- Closed items do not run again unless an explicit recovery policy selects them.
- One ready task can enter WIP only after a durable release event.
- The selection view explains why each blocked item is not ready.

## Task 9.6: Preserve discovered-work limits

Let a harness report a discovered task without granting authority to expand current scope.

Acceptance criteria:

- A small discovered task can become a child Beadwork record under configured limits.
- A material or cross-repository task creates a GitHub decision request before work starts.
- Rejected discovered work does not change the active candidate.
- The journal links the discovery to the station and evidence that found it.

## Epic exit criteria

- Hancho can pull one ready Beadwork task that links to a GitHub commitment.
- Both systems keep their separate ownership rules through success, failure, and recovery tests.
