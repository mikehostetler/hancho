# GitHub Issues and Beadwork Boundary

Status: Draft policy for later standardization

## Decision

Use GitHub Issues and Beadwork at different control levels. Do not keep two complete copies of the same work.

**GitHub records what the factory promises. Beadwork records how the factory performs the work.**

In Toyota Production System terms:

- A GitHub Issue is the customer order and commitment Kanban.
- A Beadwork item is the internal traveler that follows work through the production cell.
- A pull request is the candidate product at its final quality gate.

## Record ownership

| System | Owns |
|---|---|
| GitHub Issues | Requests, commitments, priority, acceptance conditions, owner decisions, public status, and final results. |
| Beadwork | Agent tasks, decomposition, dependencies, active work in process (WIP), blockers, execution notes, and session recovery. |
| Pull requests | Candidate code, review, CI evidence, and the merge decision. |

GitHub Issues are the system of record for accepted scope and customer acceptance. Beadwork is the system of record for internal execution state.

## Standard flow

1. Record demand in a GitHub Issue.
2. Admit, reject, or defer the issue in GitHub.
3. Create one root Beadwork item when the factory pulls the issue into active WIP.
4. Link the root Beadwork item to the GitHub Issue.
5. Decompose and manage execution in Beadwork.
6. Record material decisions and scope changes in the GitHub Issue.
7. Link the pull request to both records.
8. Close the Beadwork items when execution ends.
9. Close the GitHub Issue only after the accepted result or required delivery exists.

## Operating rules

- Do not copy detailed task lists into both systems.
- Do not treat Beadwork completion as customer acceptance.
- Do not create Beadwork items for small work that does not need decomposition or session recovery.
- Do not post routine agent progress to GitHub.
- Post blockers, changed scope, owner decisions, and delivery results to GitHub.
- Do not use automatic two-way synchronization.
- Keep every active root Beadwork item linked to one GitHub Issue, unless it is discovered work under the exception below.

## Discovered-work exception

An agent can record a small discovered task in Beadwork before a GitHub Issue exists.

Create a GitHub Issue before work starts when the discovered task:

- Changes the accepted scope.
- Needs owner priority or acceptance.
- Creates a new customer commitment.
- Has material risk or cross-repository effect.

The owner can reject or defer the new issue. Discovery does not grant authority to expand the current work.

## Questions before standardization

- What exact link format should connect a GitHub Issue and a root Beadwork item?
- Which GitHub labels, if any, should show derived execution state?
- What size or duration requires a Beadwork item?
- Should the factory close Beadwork before or after merge?
- Where should the final execution summary live?
