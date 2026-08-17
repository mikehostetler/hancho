# Hancho

Hancho is a minimal Elixir escript shell.

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

This creates `.hancho/config.toml`, `.hancho/logs/`, and `.hancho/state/`. The complete `.hancho/` folder stays local and ignored by Git.

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

Hancho uses the [`git`](https://hex.pm/packages/git) package behind `Hancho.Git`. Git processes run through erlexec so Hancho can stop a timed-out command and its child processes.
