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

Initialize Hancho in a Git repository:

```sh
./hancho init
```

This creates `.hancho/config.toml`, `.hancho/logs/`, `.hancho/prompts/`,
`.hancho/workflows/`, and `.hancho/worktrees/`. It installs the first workflow
at `.hancho/workflows/implement.yaml` and its editable agent prompt at
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

Use `Hancho.Config.load/1` to read and validate the file. Use dot-delimited keys such as `Hancho.Config.get(config, "repo.path")` to read values. If the file does not exist, `load/1` returns a validated default configuration for the repository without writing a file.

## Implementation workflow

Run the first factory workflow for one ready Beadwork task:

```sh
./hancho run implement hancho-123
```

This command stays in the foreground. The workflow does these steps in order:

1. Check the Git repository and Beadwork task.
2. Claim the task.
3. Create a detached worktree in `.hancho/worktrees/`.
4. Render and save the agent prompt.
5. Call the configured CLI coding agent through Jido.Harness.
6. Run `mix test`.
7. Create a conventional Git commit.
8. Fast-forward the original branch to the commit.
9. Remove the worktree.
10. Close and sync the Beadwork task.

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

Each run record also saves the exact loaded workflow YAML, its source path, and
its SHA-256 value. The activity log writes `workflow.snapshot` and
`prompt.snapshot` events with the exact workflow, prompt template, rendered
prompt, and matching hashes. These local audit records are intentionally not
redacted and can contain private task data.

## Factory activity logs

Hancho writes factory activity to `.hancho/logs/factory.jsonl` by default. These events contain command output, workflow changes, agent activity, and other factory work. They are separate from the normal diagnostic logs for the Hancho application.

The default JSON Lines format writes one event on each line. Each event has a schema version, sequence number, UTC timestamp, level, event name, message, message encoding, and metadata. The text format also writes one escaped event on each line.

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
