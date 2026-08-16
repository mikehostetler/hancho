# Epic 11: Plan.V1, Audit.V1, and Instruction Packs

## Goal

Prove that Hancho supports multiple state machines and reusable guidance, not only one build loop.

## Depends on

Epics 06, 08, and 10.

## Task 11.1: Implement Plan.V1

Create a read-only workflow with research, draft, review, and approval stations. Its product is a bounded Markdown plan.

Acceptance criteria:

- The workflow cannot route to an `edit_worktree` capability.
- The plan records goal, scope, tasks, dependencies, risks, checks, and acceptance criteria.
- Review findings cause plan rework without source-code changes.
- Human approval names the exact plan artifact hash.

## Task 11.2: Implement Audit.V1

Create a read-only workflow with inventory, bounded inspection, validation, report, and completion stations.

Acceptance criteria:

- The audit records a subsystem inventory and explicit ownership boundaries.
- Inspection units do not overlap unless the report records a reason.
- Validation removes duplicate or weak findings and checks material value.
- The report records evidence, priority, coverage, and explicit skip decisions.
- The target repository tree and HEAD are unchanged after the audit.

## Task 11.3: Add bounded audit fan-out

Let Audit.V1 run independent inspection units with a fixed concurrency and evidence budget.

Acceptance criteria:

- Each unit has a stable ID, exact scope, and assigned harness session.
- The scheduler does not exceed the audit WIP limit.
- A failed unit does not erase completed unit evidence.
- The validator can report missing coverage before report completion.

## Task 11.4: Define instruction packs

Add a versioned instruction-pack contract for prompt fragments, required capabilities, expected artifacts, and source attribution.

Acceptance criteria:

- A pack cannot change workflow state or authority policy.
- A work order records the pack name, version, source, and content hash.
- Configuration can enable a pack for one station without changing workflow code.
- A missing optional external skill gives a clear skip or setup result.

## Task 11.5: Add the first guidance mappings

Map the Compound Engineering loop, Impeccable design help, the canonical audit prompt, and selected Matt Pocock skills to applicable stations.

Acceptance criteria:

- Compound guidance maps brainstorm and plan to Plan.V1, and work, simplify, review, and compound to Build.V1 stations.
- Impeccable guidance activates only for admitted design work.
- Audit.V1 keeps the Aaron Francis source link as canonical and does not embed a stale full copy.
- Matt Pocock skill mappings are explicit and optional.
- Hancho can show the resolved guidance before it starts a station.

## Task 11.6: Add more harness adapters

Add a Codex built-in adapter and documented Zclaude and Pi adapters through the same protocol.

Acceptance criteria:

- A repository can route implementation to Pi and review to Codex through configuration only.
- Plan.V1 can use a different harness route from Build.V1.
- Each adapter passes the common contract suite.
- A custom local Pi adapter remains an external executable and does not load code into the BEAM.

## Epic exit criteria

- Build.V1, Plan.V1, and Audit.V1 run through the same transition, journal, decision, and harness interfaces.
- A configuration change can switch compatible harnesses without a workflow-code change.
