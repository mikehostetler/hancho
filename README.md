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

Inspect the current repository and required local tools:

```sh
./hancho doctor
```

Hancho uses [Beadwork](https://github.com/jallum/beadwork) for durable work tracking. This repository uses the `hancho` Beadwork issue prefix.

Hancho uses [Jido.Harness](https://github.com/agentjido/jido_harness) as its normalized runtime for CLI coding agents.

Hancho uses the [`git`](https://hex.pm/packages/git) package behind `Hancho.Git`. Git processes run through erlexec so Hancho can stop a timed-out command and its child processes.
