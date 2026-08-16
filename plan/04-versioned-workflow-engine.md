# Epic 04: Versioned Workflow Engine

## Goal

Implement a pure state-machine engine that can run different versioned workflows without harness-specific logic.

## Depends on

Epics 01 and 02.

## Task 4.1: Define workflow and event data

Define workflow identity, version, states, stations, events, guards, actions, terminal results, authority profiles, and evidence requirements.

Acceptance criteria:

- Data constructors reject duplicate states, events, and station IDs.
- Every workflow has an initial state and at least one terminal state.
- A workflow station requests capabilities and does not contain a harness name.
- Workflow identity and version can be serialized without Elixir-specific terms.

## Task 4.2: Implement the pure transition function

Given a workflow, current state, and event, return either a new state with requested actions or a typed rejection.

Acceptance criteria:

- The function does not read files, time, environment, processes, or the database.
- The same input always gives the same output.
- An event that is not valid for the current state cannot change the state.
- Tests cover all transitions and all rejected events in the walking-skeleton workflow.

## Task 4.3: Add guards, authority, and evidence checks

Make state transitions depend on explicit facts instead of action success text.

Acceptance criteria:

- A missing approval produces a decision request or a typed stop.
- A missing required artifact cannot pass a quality gate.
- The engine separates an action request from the later action result event.
- A stale event for an earlier state cannot advance the current state.

## Task 4.4: Add the workflow behavior and registry

Use versioned Elixir modules such as `Hancho.Workflows.Build.V1`. Add a registry for discovery and validation.

Acceptance criteria:

- `hancho workflow list` shows every installed workflow and version.
- `hancho workflow show NAME` shows states, stations, capabilities, and transitions.
- `hancho workflow validate NAME` finds an unreachable state and a missing route.
- A work order pins one workflow name and version for its full life.

## Task 4.5: Add the walking-skeleton workflow

Create a small workflow that sends one request to a fake harness and records success, failure, cancellation, and Andon results.

Acceptance criteria:

- The success path reaches a terminal `complete` result.
- A harness failure reaches a visible stopped state.
- Cancellation reaches a different terminal result from failure.
- Restarting with a newer workflow module does not change an existing pinned run.

## Epic exit criteria

- The engine can execute the walking-skeleton workflow without Git, SQLite, or an external harness.
- Workflow validation stops invalid definitions during startup.
