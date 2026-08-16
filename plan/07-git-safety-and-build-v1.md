# Epic 07: Git Safety and Build.V1

## Goal

Produce one verified candidate commit from a bounded work order without letting a harness control Git acceptance effects.

## Depends on

Epics 04, 05, and 06.

## Task 7.1: Implement Git preflight and isolated worktrees

Validate the control checkout and create one detached execution worktree at a pinned baseline commit.

Acceptance criteria:

- A dirty control checkout stops the first parity mode before work starts.
- The journal stores the baseline commit, target branch, worktree path, and Git common directory.
- A harness receives only the execution worktree path.
- Hancho retains a failed worktree for inspection and can remove an accepted worktree safely.

## Task 7.2: Implement admitted scope checks

Load allowed paths from the work order and check every tracked, untracked, renamed, copied, and deleted path.

Acceptance criteria:

- A change inside an exact file scope passes.
- A change inside an allowed directory scope passes.
- An out-of-scope or escaped path causes an Andon stop before commit.
- Hancho reports each rejected path and does not silently accept it.

## Task 7.3: Implement gates and authority checks

Add explicit gates for dependency files, migrations, high-risk changes, and configured project rules.

Acceptance criteria:

- Changes to `mix.exs` or `mix.lock` need the configured dependency approval.
- Phoenix migration paths need the configured migration approval.
- An approval records actor, reason, time, scope, and candidate revision.
- Approval for one revision cannot approve a different revision silently.

## Task 7.4: Implement Elixir verification profiles

Support a default Elixir library profile, a private Phoenix profile, and repository-configured check commands.

Acceptance criteria:

- The default profile checks format, compilation with warnings as errors, and tests.
- The Phoenix profile can add migration, asset, security, and smoke checks without code changes in Hancho.
- Each check records command, working directory, start, end, exit status, and output artifact.
- A failed required check stops the candidate from acceptance.

## Task 7.5: Implement bounded repair

Send failed-check evidence back through an edit-capable harness station with a fixed attempt limit.

Acceptance criteria:

- Each repair uses a fresh harness session.
- Scope and Git ownership checks run after every repair.
- The run stops with an Andon record when the limit is reached.
- A repair cannot change the pinned work order or its acceptance conditions.

## Task 7.6: Implement Hancho-owned candidate commits and receipts

After all required checks pass, stage allowed changes, create one candidate commit, verify it again, and write a receipt.

Acceptance criteria:

- A harness-created commit causes a stop.
- The candidate commit message links the work order and work reference.
- Checks run against the exact candidate commit.
- The receipt includes the baseline, candidate commit, changed paths, checks, harness identity, workflow version, configuration hash, and approvals.
- Build.V1 ends at `candidate_ready`; merge and push require a separate effect policy.

## Task 7.7: Add Build.V1 independent review

Route the verified candidate to a review-capable harness or a durable human decision.

Acceptance criteria:

- Configuration can require a reviewer different from the implementer harness.
- Review findings create visible rework or rejection events.
- Review acceptance names the exact candidate commit.
- High-risk rules can require a human approval after harness review.

## Epic exit criteria

- A fixture Elixir project can move from a work reference to a verified, reviewed candidate commit.
- Tests prove that scope, failed checks, missing gates, a changed target branch, and harness Git actions stop acceptance.
