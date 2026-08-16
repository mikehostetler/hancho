# Epic 06: Harness Protocol, Adapters, and Routing

## Goal

Run CLI coding harnesses through one safe, versioned contract.

## Depends on

Epics 03, 04, and 05.

## Task 6.1: Define harness protocol version 1

Define `doctor`, `version`, and `run` operations. Define the request, event, result, and error JSON schemas.

Acceptance criteria:

- A request includes run, workflow, station, repository, worktree, prompt, capability, authority, limits, and artifact paths.
- A result includes status, adapter identity, harness identity, session identity, exit data, and raw log paths.
- The protocol rejects unknown required fields and an unsupported protocol version.
- The contract states that harness output cannot declare a Git or workflow effect complete.

## Task 6.2: Implement the adapter behavior and fake adapter

Create one Elixir behavior and a deterministic fake adapter for all tests.

Acceptance criteria:

- The fake can emit success, failure, timeout, malformed output, and slow-output cases.
- Tests can assert the exact request sent to the fake.
- The fake never starts an operating-system process.
- The walking-skeleton workflow completes through the adapter behavior.

## Task 6.3: Implement external executable adapters

Run a repository-local adapter as a separate process. Send a normalized request and read normalized JSON Lines events and a final result.

Acceptance criteria:

- A custom adapter can be written as a shell fixture with no Elixir code.
- Hancho captures standard output and standard error in separate artifact files.
- Invalid JSON, an early exit, and a missing final result produce typed failures.
- Relative adapter paths resolve from the control repository and cannot escape permitted configuration.

## Task 6.4: Implement process limits and cancellation

Use ports and an operating-system process boundary to enforce time, output, retry, and cancellation limits.

Acceptance criteria:

- A timed-out harness becomes a failed or stopped action with evidence.
- Cancellation stops the adapter and its child-process fixture within a fixed test limit.
- Hancho continues to drain and store available output during shutdown.
- A forced stop is distinct from a normal harness failure.

## Task 6.5: Implement capability routing and harness inspection

Resolve each station to a compatible configured harness. Add `hancho harness list` and `hancho harness doctor [NAME]`.

Acceptance criteria:

- A missing capability stops the run before the adapter starts.
- The journal stores the resolved adapter path, command, versions, capabilities, authority profile, and configuration hash.
- A workflow can route implementation and review to different harnesses.
- Doctor does not expose environment-variable values.

## Task 6.6: Add the first real harness adapter

Implement a Grok adapter first to support parity with the Bash driver. Keep model and permission options in adapter configuration.

Acceptance criteria:

- The adapter can run a read-only prompt in a test repository.
- The adapter normalizes success, model failure, CLI failure, and timeout.
- Hancho denies commit and push actions through the harness configuration where the harness supports that control.
- Contract tests use a fixture executable by default. A real Grok smoke test is optional and clearly marked.

## Epic exit criteria

- The walking skeleton works with the fake adapter and the external executable adapter.
- A real adapter can run without adding harness-specific code to a workflow.
