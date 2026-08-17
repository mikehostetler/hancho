# Hancho

Hancho is a minimal Elixir escript shell.

Build and run it:

```sh
mix escript.build
./hancho --help
```

Print the installed version with `./hancho --version`.

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
```

Use `Hancho.Config.load/1` to read and validate the file. Use dot-delimited keys such as `Hancho.Config.get(config, "repo.path")` to read values. If the file does not exist, `load/1` returns a validated default configuration for the repository without writing a file.

Inspect the current repository and required local tools:

```sh
./hancho doctor
```

Hancho uses [Beadwork](https://github.com/jallum/beadwork) for durable work tracking. This repository uses the `hancho` Beadwork issue prefix.

Hancho uses [Jido.Harness](https://github.com/agentjido/jido_harness) as its normalized runtime for CLI coding agents.

Hancho uses the [`git`](https://hex.pm/packages/git) package behind `Hancho.Git`. Git processes run through erlexec so Hancho can stop a timed-out command and its child processes.
