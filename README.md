# Hancho

Hancho is a minimal Elixir escript shell.

Build and run it:

```sh
mix escript.build
./hancho
```

The executable prints its version and exits.

Inspect the current repository and required local tools:

```sh
./hancho doctor
```

Hancho uses [Beadwork](https://github.com/jallum/beadwork) for durable work tracking. This repository uses the `hancho` Beadwork issue prefix.

Hancho uses [Jido.Harness](https://github.com/agentjido/jido_harness) as its normalized runtime for CLI coding agents.
