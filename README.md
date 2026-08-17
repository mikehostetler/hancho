# Hancho

Hancho is an Elixir escript that manages a software factory for one Git repository.

Build and run it:

```sh
mix escript.build
./hancho --help
```

Print the installed version with `./hancho --version`.

Run all unit, integration, compile, formatting, and escript checks with:

```sh
mix check
```

This command runs normal and cross-process tests. It then builds and smoke-tests
a production escript and confirms that the test Harness adapter is not in the
archive.

The integration suite uses a Hancho-local `Jido.Harness` adapter. The adapter
does not call a live coding provider. It produces fixed events and makes a
fixed file change. This keeps the full workflow, run manager, event journal,
Git, worktree, and Bedrock test deterministic. Tests that call a live provider
must be separate and explicit because they need credentials and can have a
cost.

Initialize Hancho in a Git repository:

```sh
./hancho init
```

This creates `.hancho/config.toml`, `.hancho/logs/`, `.hancho/prompts/`,
`.hancho/workflows/`, and `.hancho/worktrees/`. Runtime files also include the
factory lease at `.hancho/factory.lock` and Harness operation journals in
`.hancho/harness/`. It installs the first workflow at
`.hancho/workflows/implement.yaml` and its editable agent prompt at
`.hancho/prompts/implement.md`. The complete `.hancho/` folder stays local and
ignored by Git. Initialization does not replace an existing workflow or prompt.

The distributed sources are `priv/workflows/implement.yaml` and
`priv/prompts/implement.md`. Hancho embeds both files when it builds the escript
and copies them into the repository during initialization.

The initial configuration is:

```toml
version = 1

[repo]
path = "/path/to/repository"

[logs]
enabled = true
path = "factory.jsonl"
format = "jsonl"
console = true
include_internal = false
sync_interval_ms = 1000
max_bytes = 10485760
max_files = 5
compress = true
```

Use `Hancho.Config.load/1` to read and validate the file. Use dot-delimited keys
such as `Hancho.Config.get(config, "repo.path")` to read values. The configured
repository path must resolve to the repository that Hancho discovered. If the
file does not exist, `load/1` returns a validated default configuration for the
repository without writing a file.

## Implementation workflow

Run the first factory workflow for one ready Beadwork task:

```sh
./hancho run implement hancho-123 --verbose
```

This command stays in the foreground. `--verbose` also streams safe summaries
of normalized provider events while the coding agent works. The workflow does
these steps in order:

1. Check the Git repository and Beadwork task.
2. Claim the task.
3. Create a detached worktree in `.hancho/worktrees/`.
4. Render and save the agent prompt.
5. Call the configured CLI coding agent through Jido.Harness.
6. Check changed paths against the Beadwork `Allowed Scope`, when configured.
7. Run `mix test`.
8. Create a conventional Git commit.
9. Fast-forward the original branch to the commit.
10. Remove the worktree.
11. Close and sync the Beadwork task.

The YAML file names each step, selects one approved `Jido.Action` module, and
sets its parameters. References are explicit:

- `$input.key` reads command input.
- `$run.id` reads the durable run ID.
- `$steps.step_name.key` reads an earlier step result.

Workflow structure does not use `config.toml`. Edit the repository-local YAML
file to change action parameters. Hancho permits only action modules in
`Hancho.Workflow.Registry`; it does not create atoms from YAML module names.

The `Hancho.Actions.RenderPrompt` action accepts exactly one prompt source. A
file source is relative to `.hancho/prompts/`:

```yaml
params:
  repo_path: "$steps.preflight.repo_path"
  prompt_file: implement.md
  context:
    issue: "$steps.claim.issue"
```

Small prompts can be inline YAML block strings:

```yaml
params:
  repo_path: "$steps.preflight.repo_path"
  prompt: |
    Implement {{issue.id}}: {{issue.title}}

    {{issue.description}}
  context:
    issue: "$steps.claim.issue"
```

Prompt variables use `{{context.path}}` syntax. Hancho stops if a variable is
not present. The prompt-rendering step saves the exact template, rendered
prompt, source, and SHA-256 values before the CLI agent starts.

Hancho records every run and step in a local Bedrock cluster at
`.hancho/bedrock/`. A successful step saves its result in an atomic transaction
before the next step starts. If a step fails, Hancho stops the line, records the
failed step and error, and returns a nonzero exit status. It keeps a failed
implementation worktree for inspection when cleanup has not started. Bedrock
stores its cluster descriptor, coordinator, log, and storage-worker files in
this repository-local folder. Before the command returns, Hancho closes
Bedrock's five-second in-memory storage window and verifies a durability marker.
Run, step, and queue records have explicit schema and transition versions.
Hancho upgrades older records when it reads them.

Hancho records an intent before each external effect and records a receipt
after the effect completes. Effects include task claims, worktree changes,
commits, landing, cleanup, task closure, and task synchronization. On recovery,
Hancho reconciles an incomplete intent with Git, Beadwork, or the filesystem
before it continues.

Each run record also saves the exact loaded workflow YAML, its source path, and
its SHA-256 value. The activity log writes `workflow.snapshot` and
`prompt.snapshot` events with the exact workflow, prompt template, rendered
prompt, and matching hashes. These local audit records are intentionally not
redacted and can contain private task data.

## Foreground queues

Run an explicit number of ready Beadwork tasks through one workflow:

```sh
./hancho queue implement --source beadwork-ready --count 5 --verbose
```

Preview the exact task selection and run read-only repository reconciliation
without writing state, claiming work, creating a worktree, or calling an agent:

```sh
./hancho queue implement --source beadwork-ready --count 1 --dry-run
```

The preview reports the branch, commit, clean status, retained worktree count,
provider, and implementation and verification timeouts. It also compiles the
workflow and checks action modules, parameters, references, prompt files,
provider readiness, and required executables. A repository, worktree, or
workflow error stops the preview before a live run can start.

If `bw ready` returns fewer tasks than the requested count, Hancho derives ready
tasks from `bw list --all`. A task is ready when it is open or in progress and
each named blocker is closed or is an earlier task in the same serial queue.
Execution cards with a `Queue ordinal` in their description are selected in
that order. A task with another unresolved blocker is not selected.

Hancho first reads `bw ready --json` and keeps ready items with the `task` type.
It uses the full-list fallback described above only when that command returns
too few tasks. Hancho requires the requested number before it starts. It saves
their order in Bedrock and runs one child workflow at a time. Each child has a
deterministic run ID such as `queue-123-001` and keeps its normal workflow,
prompt, step, and log snapshots.

The command stays in the foreground and stops on the first failed child. It
does not retry, skip, repair, or continue. `--verbose` prints queue selection,
the checks before and after each child, child run IDs, landed commits, and the
terminal queue result. During implementation it also prints normalized provider
text, thought, tool, file, plan, usage, approval, and terminal updates. Tool
results are summarized; Hancho does not print their full payloads to the
console. Normal mode keeps the short periodic implementation progress lines.
Hancho also saves queue events in the factory log:

- `queue.started`
- `queue.reconciled`
- `queue.item_started`
- `queue.item_completed`
- `queue.stopped`
- `queue.reconciliation_failed`
- `queue.completed`

At queue creation and each child boundary, Hancho compares durable queue state
with the local repository. The main branch, HEAD, and clean status must match.
The `.hancho/worktrees/` directories and Git worktree registrations must also
match the child workflow state. A mismatch stops the queue with a
`filesystem_out_of_sync` error. Hancho does not delete worktrees, prune Git
state, reset HEAD, or change branches to repair a mismatch.

One Hancho factory can own a repository at a time. The factory lease has a
heartbeat. A new process can reclaim a stale lease after the recorded owner
process ends.

## Retry and resume

Continue one stopped workflow from its stopped step:

```sh
./hancho retry RUN_ID --verbose
```

Hancho keeps completed step outputs and does not run completed steps again. It
can also recover a run that ended while a step was running. It checks the saved
main-branch commit, retained worktree, and pending external effects before it
changes durable state. A mismatch stops the retry.

Continue one stopped queue from its stopped child:

```sh
./hancho resume QUEUE_ID --verbose
```

Hancho retries the stopped child with its original run ID. If the queue stopped
before that child created a run, Hancho starts the child with the saved run ID.
After that child completes, Hancho runs the pending children in their saved
order. Completed children do not run again. Queue activity includes
`queue.resumed`, `queue.item_retried`, and `queue.item_restarted` events.
Workflow activity includes a `workflow.retry_started` event.

## Run inspection

Read one durable run without starting or changing it:

```sh
./hancho run inspect RUN_ID
```

The report shows the workflow status, start and finish times, step durations,
provider and Harness run IDs, verification summary, landed or created commit,
retained worktree, and failure data.

During implementation, Hancho records an `implement.progress` event every 30
seconds by default. It records the Harness run ID, elapsed time, observed event
count, and latest normalized event type. It does not copy raw provider output
into the progress event. Set `progress_interval_ms` on the implementation step
to change the interval.

Verification writes complete merged standard output to a protected file in
`.hancho/logs/`. Factory activity contains one `verify.progress` event per 64
KiB and one `verify.completed` summary. It does not write one factory event for
each test-runner output chunk. `hancho run inspect` reports the complete output
path.

Command results keep a bounded output tail in memory. They report total output
bytes and whether the in-memory result was truncated. The full verification
log remains available at the protected output path.

## Retained worktrees

List retained worktrees and their total storage use:

```sh
./hancho worktrees list
```

Inspect Git registration, commit, changed paths, and generated storage for one
run:

```sh
./hancho worktrees inspect RUN_ID
```

Remove only `_build`, `deps`, and `cover` from one registered retained
worktree:

```sh
./hancho worktrees clean RUN_ID
```

The clean command keeps the worktree, Git registration, source changes, and
all other diagnostic files.

## Factory activity logs

Hancho writes factory activity to `.hancho/logs/factory.jsonl` by default. These events contain command output, workflow changes, agent activity, and other factory work. They are separate from the normal diagnostic logs for the Hancho application.

The default JSON Lines format writes one event on each line. Each event has a
schema version, sequence number, UTC timestamp, level, event name, message,
message encoding, and metadata. A sequence sidecar keeps sequence numbers
monotonic across writer restarts. The text format also writes one escaped event
on each line. Audit write failures are reported, but they do not replace the
factory operation result.

The log options have these effects:

- `enabled` starts or stops activity logging.
- `path` sets a safe path inside `.hancho/logs/`.
- `format` is `jsonl` or `text`.
- `console` sends captured events to the console as well as the file.
- `include_internal` also captures Hancho Logger events that use the `[:hancho]` domain.
- `sync_interval_ms` sets the file-sync interval. A value of `0` syncs after each event.
- `max_bytes` rotates the current file at the given size.
- `max_files` sets how many old files remain.
- `compress` compresses rotated files with gzip.

Use `Hancho.Log` to own one activity log for a factory run:

```elixir
{:ok, project} = Hancho.Project.discover()
{:ok, config} = Hancho.Config.load(project)
{:ok, log} = Hancho.Log.open(project, config, metadata: %{run_id: "build-42"})

:ok = Hancho.Log.write(log, "step started", event: "workflow.step_started")

sink = Hancho.Log.output_sink(log, metadata: %{command: "mix test"})
{:ok, result} = Hancho.Command.run("mix", ["test"], cwd: project.root, on_output: sink)

:ok = Hancho.Log.close(log)
```

The writer serializes events. It uses Elixir Logger metadata and the OTP file handler for filtering, file sync, rotation, compression, and console routing. `Hancho.Command` stops its process group if the activity sink cannot write an output event.

Inspect the current repository and required local tools:

```sh
./hancho doctor
```

Hancho uses [Beadwork](https://github.com/jallum/beadwork) for durable work tracking. This repository uses the `hancho` Beadwork issue prefix.

Hancho uses [Jido.Harness](https://github.com/agentjido/jido_harness) as its normalized runtime for CLI coding agents.

Hancho uses [Jido.Action](https://hex.pm/packages/jido_action) for validated
workflow actions and [yaml_elixir](https://hex.pm/packages/yaml_elixir) for
workflow definitions. Hancho uses [Bedrock](https://github.com/bedrock-kv/bedrock)
for durable, repository-local workflow state. The dependency points directly to
the tested `hancho/bedrock-next` integration commit in Mike Hostetler's Bedrock
fork. That commit combines the current upstream recovery stack with the
layout-index fixes required by Hancho.

Hancho uses the [`git`](https://hex.pm/packages/git) package behind `Hancho.Git`. Git processes run through erlexec so Hancho can stop a timed-out command and its child processes.
