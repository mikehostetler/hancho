# Epic 12: Acceptance, Delivery, and Feedback

## Goal

Move an accepted candidate through guarded Git effects, optional delivery, observation, and work closure.

## Depends on

Epics 07, 08, and 09.

## Task 12.1: Implement candidate publication

Create or update a Hancho-owned branch and publish the exact candidate commit under explicit policy.

Acceptance criteria:

- Push intent is durable before the push starts.
- Reconciliation can prove whether the remote contains the candidate commit.
- Hancho never uses a force push in the default policy.
- The receipt links the local and remote candidate revisions.

## Task 12.2: Implement pull request effects

Create or update a pull request through a configured GitHub CLI adapter and attach the issue, Beadwork, checks, and receipt references.

Acceptance criteria:

- One work order does not create duplicate pull requests after recovery.
- The pull request names the exact candidate commit and target branch.
- Hancho records CI and review evidence as observations, not as model claims.
- A failed GitHub request leaves a reconcilable effect.

## Task 12.3: Implement guarded merge

Merge only after target freshness, required CI, review, authority, and no-stop conditions pass.

Acceptance criteria:

- A changed target branch requires new validation or an explicit policy transition.
- Merge authority is separate from harness review authority when policy requires it.
- The merged commit is observed from GitHub or Git before the workflow advances.
- An uncertain merge cannot run again until reconciliation.

## Task 12.4: Define delivery adapters

Use a separate effect contract for Hex publication and private Phoenix deployment. Keep the first implementation opt-in.

Acceptance criteria:

- A delivery request names the artifact, target environment, authority, checks, and recovery method.
- The adapter protocol separates requested, started, confirmed, uncertain, contained, and reversed results.
- A dry-run validates the delivery plan without an external write.
- Secrets enter through named environment variables and do not enter persisted configuration.

## Task 12.5: Implement observation and closure

Record the receiver result, delivery status, useful learning, Beadwork closure, and GitHub Issue closure in the required order.

Acceptance criteria:

- Merge alone does not close work that requires delivery.
- Beadwork completion does not mean customer acceptance.
- The GitHub Issue final note contains the result and evidence links, not routine execution detail.
- A useful learning can create a versioned standard-work proposal without changing the current workflow silently.

## Epic exit criteria

- A configured Build.V1 can end at candidate, pull request, merge, or delivered result under explicit policy.
- All irreversible or difficult-to-repeat effects use intent, observation, and reconciliation.
