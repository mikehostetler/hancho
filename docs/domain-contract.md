# Hancho Domain Contract

## Terms

| Term | Contract |
|---|---|
| Factory Unit | One control checkout, its Git repository, and its ignored `./.hancho/` folder. |
| Workflow | A named and versioned state machine. |
| Station | One bounded workflow step that requests a capability. |
| Operator | A configured CLI harness adapter that supplies a capability. |
| Work Order | One run of one pinned workflow version for one work reference. |
| Journal | The append-only record of events, decisions, actions, effects, and evidence. |
| Action | Work that Hancho requests after a valid transition. |
| Effect | An action that changes Git, GitHub, Beadwork, a release target, or a deployment target. |
| Decision | Durable human input for one exact request and candidate. |
| Andon | A visible stop for an abnormal, unsafe, or uncertain condition. |

## Ownership

- The workflow engine owns valid state transitions.
- The journal owns durable facts about a work order.
- Hancho action modules own external effects.
- A harness owns its command syntax, input transport, and output decoding.
- GitHub Issues own commitments and acceptance conditions.
- Beadwork owns internal execution tasks and dependencies.
- People own purpose, policy, approvals, and exception decisions.

A harness can read or edit its assigned worktree under its authority profile. It cannot commit, push, merge, release, deploy, or close a work item. Harness text is evidence input. It is not proof that an effect occurred.

A command sends an event. It does not set an arbitrary workflow state. The engine checks the current state, event, authority, and evidence before it returns the next state and requested actions.

## Build.V1 example

1. The owner accepts a GitHub Issue.
2. Beadwork records the execution task.
3. Hancho releases the work order when capacity and dependencies permit it.
4. Hancho pins the workflow version, repository baseline, accepted scope, and configuration hash.
5. Hancho creates an isolated worktree.
6. An edit-capable harness changes only the admitted scope.
7. Hancho checks scope and runs the Elixir verification profile.
8. A bounded repair station can correct a failed check.
9. Hancho creates and verifies the candidate commit.
10. A separate review station checks the exact candidate.
11. Hancho records a receipt and stops at `candidate_ready` unless effect policy permits publication or merge.
12. An effect intent is durable before publication, merge, delivery, or work closure.
13. Hancho records the observed result after the effect.

An invalid event, failed gate, missing authority, changed target, or uncertain effect creates a rejection, decision request, or Andon stop. It does not silently advance work.
