# Epic 10: Continuous Factory and Tmux Host

## Goal

Keep one local factory active, control WIP, and let the user watch it in the foreground or in a detached tmux session.

## Depends on

Epics 08 and 09.

## Task 10.1: Implement the factory controller

Start one supervised controller for one `./.hancho/` folder. Own the factory lock, process metadata, and local control channel.

Acceptance criteria:

- A second controller cannot acquire the same factory.
- Stale process metadata does not block a safe restart.
- `factory.json` identifies the host, process, start time, configuration hash, and health state.
- A control command is authenticated by local file permissions and factory identity.

## Task 10.2: Implement the pull scheduler and WIP limits

Poll or receive a ready-work signal, release permitted work, and supervise each active work order.

Acceptance criteria:

- No more work starts after the configured WIP limit is full.
- A blocked item does not consume an implementation slot before release.
- An idle factory waits without creating empty work orders.
- One failed work order does not crash unrelated active work.
- `hancho run WORKFLOW WORK_REF --detach` submits to the active controller and returns after durable acceptance.

## Task 10.3: Implement foreground `hancho up`

Validate the factory, reconcile interrupted work, start scheduling, and show normalized events.

Acceptance criteria:

- Startup stops before release when required doctor checks fail.
- The first interrupt stops new releases and requests a safe boundary.
- The second interrupt records an abnormal stop before forced termination when possible.
- A restart reconciles incomplete actions before it releases more work.

## Task 10.4: Implement control commands

Add idempotent `hancho down`, `hancho pause`, `hancho continue`, and `hancho status` commands.

Acceptance criteria:

- Repeated control commands do not create duplicate factory state events.
- Pause stops new release and does not discard active evidence.
- Status shows host, health, WIP, ready work, active work, blocks, decisions, Andon, uncertain effects, and the likely next command.
- Read-only status works when the controller is stopped.

## Task 10.5: Implement the tmux host

Add `hancho up --tmux`, `hancho up -d`, and `hancho attach` with tmux as the first background host.

Acceptance criteria:

- A detached start returns only after the controller reports healthy or failed.
- The session name is stable and unique for the local factory.
- A second detached start does not create a second session or controller.
- If tmux is unavailable, Hancho gives a clear error and does not use `nohup`.
- `attach` reports a useful next action when no session exists.

## Task 10.6: Test controller failure and recovery

Stop the controller during a harness action, a database transaction, and an external-effect window.

Acceptance criteria:

- A database transaction is complete or absent after restart.
- An interrupted harness action is visible and does not become success.
- An external effect with intent but no observation becomes uncertain.
- The factory does not release new work until required reconciliation ends.

## Epic exit criteria

- `hancho up` can operate an idle and active factory for an extended local test.
- Foreground and tmux modes use the same engine, database, journal, and recovery rules.
