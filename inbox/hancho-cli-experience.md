# Hancho CLI Experience Proposal

Status: First proposal

## Goal

The `hancho` binary controls one software factory from the current Git repository.

By default, Hancho finds the repository root and uses:

```text
./.hancho/
```

The primary experience is one command that turns on the factory and shows its live operation:

```text
hancho up
```

The factory stays active when no work is ready. It waits for the next pull signal instead of exiting.

## Main operating modes

### Foreground

```text
hancho up
```

This command:

1. Finds the repository and `.hancho/config.toml`.
2. Validates the configuration and required CLI harnesses.
3. Acquires the repository factory lock.
4. Opens SQLite and reconciles incomplete work.
5. Starts the work scheduler and workflow supervisors.
6. Shows the live structured event stream in the terminal.
7. Waits when no work is ready.

The first interrupt requests a safe shutdown. Hancho stops releasing new work, asks active harnesses to stop at a safe boundary, writes final events, and exits. A second interrupt forces termination and records an abnormal stop on the next startup.

### Detached tmux host

```text
hancho up --tmux
```

This command creates a detached, repository-specific tmux session and returns after Hancho reports that the factory is healthy.

The command prints:

- The factory ID.
- The tmux session name.
- The process state.
- `hancho attach` and `hancho logs --follow` suggestions.

Use:

```text
hancho attach
```

to attach to the tmux session.

Support this convenience alias:

```text
hancho up -d
```

For the first version, `-d` uses the configured background host. The default background host is tmux. If tmux is not available, Hancho stops with a clear error. It must not silently fall back to `nohup` or an unmanaged child process.

Later versions can add `launchd` and `systemd` hosts behind the same interface.

## Factory-control commands

| Command | Purpose |
|---|---|
| `hancho init` | Create `./.hancho/`, initial configuration, SQLite state, and the `.gitignore` rule. |
| `hancho doctor` | Validate Git, Beadwork, configuration, storage, tmux, workflows, and configured harnesses. |
| `hancho up` | Start the continuous factory in the foreground and show live events. |
| `hancho up --tmux` | Start the continuous factory in a detached tmux session. |
| `hancho down` | Request a safe factory shutdown. |
| `hancho down --force` | Stop the factory after it records an abnormal termination request. |
| `hancho pause` | Stop the release of new work. Let active work continue to its next safe boundary. |
| `hancho continue` | Permit the factory to release ready work again. |
| `hancho status` | Show factory health, work in process, queues, stops, and open decisions. |
| `hancho logs --follow` | Follow the normalized factory event stream. |
| `hancho attach` | Attach to the configured interactive process host, initially tmux. |

`hancho up`, `hancho down`, `hancho pause`, and `hancho continue` must be idempotent. A second `hancho up --tmux` must not create a second factory.

## Work-order commands

| Command | Purpose |
|---|---|
| `hancho run WORKFLOW WORK_REF` | Start one explicit work order, such as `hancho run build bw-123`. |
| `hancho runs` | List recent and active work orders. |
| `hancho show RUN_ID` | Show one work order, its current state, evidence, decisions, and effects. |
| `hancho resume RUN_ID` | Request continuation from a safe stopped or interrupted state. |
| `hancho retry RUN_ID` | Request a policy-permitted retry of the failed station. |
| `hancho cancel RUN_ID --reason TEXT` | Request controlled cancellation and preserve evidence. |
| `hancho reconcile RUN_ID` | Compare uncertain effects with Git, Beadwork, or another external target. |

`hancho run` uses the active factory when one exists. If the factory is not active, it starts a one-work-order foreground controller. It uses the same workflow engine, journal, and safety rules in both cases.

The default `hancho run` output follows the work order until it reaches a terminal state, a human decision, or an Andon stop. Use `--detach` to return after submission.

## Queue and decision commands

| Command | Purpose |
|---|---|
| `hancho queue` | Show ready, active, blocked, deferred, and stopped work. |
| `hancho decisions` | List decisions that need human input. |
| `hancho approve DECISION_ID --reason TEXT` | Record approval and send the permitted event to the workflow. |
| `hancho reject DECISION_ID --reason TEXT` | Record rejection and send the rejection event to the workflow. |

Background operation must never wait for an interactive terminal question. It records a durable decision request and continues other permitted work.

Approval does not force a state. It adds an event. The workflow checks the event, authority, evidence, and current state before it permits a transition.

## Inspection and configuration commands

```text
hancho config show
hancho config validate

hancho workflow list
hancho workflow show build
hancho workflow validate build

hancho harness list
hancho harness doctor
hancho harness doctor pi
```

These commands help the user inspect the resolved configuration before Hancho performs work. `config show` must redact secret values and show the source of each resolved setting.

## Status experience

`hancho status` should answer these questions in one screen:

- Is the factory running, paused, stopping, stopped, or unhealthy?
- Where does the active process run: foreground, tmux, or another host?
- Which workflow and configuration versions are active?
- Which harnesses are available and healthy?
- What work is ready, active, blocked, stopped, or waiting for a decision?
- What is the current work-in-process limit and use?
- Are any external effects uncertain?
- What command is the likely next action?

Example:

```text
Factory: operating     Host: tmux (hancho-wayfinder-a13f)
Workflow set: v1       Config: 7c31a2d
WIP: 1/2               Ready: 3  Blocked: 1
Decisions: 1           Andon: 0  Uncertain effects: 0

ACTIVE
  run-104  build  bw-a13f  verifying  harness=pi

NEXT ACTION
  hancho approve decision-22 --reason "Migration reviewed"
```

## Log experience

The normal log view is a structured event stream, not raw harness output.

```text
12:04:11 run-104 build implementing harness.started harness=pi
12:07:42 run-104 build implementing harness.completed result=success
12:07:43 run-104 build verifying check.started name=mix-precommit
12:09:01 run-104 build verifying check.failed exit=1
12:09:01 run-104 build rework repair.requested attempt=1/2
```

Useful filters include:

```text
hancho logs --follow
hancho logs --run run-104
hancho logs --run run-104 --raw
hancho logs --station verifying
hancho logs --since 30m
```

Raw harness output remains in the run artifact folder. The normalized event stream remains the default because it shows factory state and transitions.

## Process control

One factory controller can operate one local `.hancho/` folder at a time.

The controller owns:

- A lock in `.hancho/locks/`.
- A local control socket at `.hancho/control.sock`.
- Host and process metadata in `.hancho/factory.json`.

Other `hancho` commands send control events through the socket. Read-only commands can read SQLite when the factory is stopped. A state-changing offline command must acquire the exclusive factory lock.

The tmux session is not durable state. If tmux or the machine stops, the next `hancho up` uses SQLite and the journal to identify interrupted actions and uncertain effects before it releases more work.

## Command design rules

- Commands send events. They do not set arbitrary workflow states.
- Every state-changing command records the actor, time, reason, prior state, and resulting event.
- Read commands support `--json` for scripts.
- Non-interactive output does not use terminal color or prompts.
- IDs are stable and easy to copy.
- Errors state what failed, what remains safe, and the next useful command.
- Background operation never hides an Andon stop or human decision request.
- Destructive cleanup and force-stop operations require explicit flags.

## Suggested first release

Implement this minimum command set first:

```text
hancho init
hancho doctor
hancho up
hancho up --tmux
hancho down
hancho status
hancho logs --follow
hancho attach
hancho run WORKFLOW WORK_REF
hancho runs
hancho show RUN_ID
hancho resume RUN_ID
hancho cancel RUN_ID --reason TEXT
hancho reconcile RUN_ID
hancho decisions
hancho approve DECISION_ID --reason TEXT
hancho reject DECISION_ID --reason TEXT
hancho harness list
hancho harness doctor [NAME]
hancho workflow list
hancho workflow show NAME
```

Add pause, continue, retry, advanced log filters, native service hosts, and a full-screen terminal user interface after the core lifecycle is stable.

## Open questions

- Should `hancho up -d` always mean tmux, or use a configurable background host?
- Should foreground interruption stop active harnesses or let them reach a station boundary?
- How does `hancho run` choose a workflow when the user omits the workflow name?
- Which Beadwork state or label makes an item eligible for automatic release?
- Should `hancho attach` open tmux or show a Hancho terminal user interface inside tmux?
- What is the best default retention period for the live factory event log?
