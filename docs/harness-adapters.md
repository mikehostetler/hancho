# Harness adapters

Hancho routes a station capability to a configured CLI harness. Workflow code does not name a model provider.

## Codex

Use the built-in adapter when the `codex` CLI is installed:

```toml
[harnesses.codex]
adapter = "builtin:codex"
command = "codex"
capabilities = ["read", "edit_worktree", "review"]
```

The adapter selects a read-only sandbox for read and review stations. It selects a workspace-write sandbox for an admitted edit station.

## Pi and Zclaude

Pi and Zclaude stay outside the BEAM. Add a local executable that implements Hancho harness protocol version 1:

```toml
[harnesses.pi]
adapter = ".hancho/harnesses/pi"
command = "pi"
capabilities = ["read", "edit_worktree"]

[harnesses.zclaude]
adapter = ".hancho/harnesses/zclaude"
command = "zclaude"
capabilities = ["read", "edit_worktree", "review"]

[routes.build]
implement = "pi"
review = "codex"

[routes.plan]
research = "zclaude"
draft = "zclaude"
review = "codex"
```

Each executable must support `doctor`, `version`, and `run REQUEST_FILE`. It must return the normalized JSON Lines result. Hancho does not load custom adapter code into the Elixir virtual machine.
