# Hancho CLI Harness Adapters and Routing

Status: Early design idea

## Scope

Hancho coordinates command-line coding harnesses only.

Initial harnesses can include:

- Grok.
- Zclaude.
- Codex.
- Pi.
- A custom local harness.

Hancho does not link directly to provider SDKs or model APIs. Each harness runs as an external process.

## Main rule

A workflow requests a capability. Repository-local configuration selects the CLI harness that supplies that capability for a station.

For example:

- A build implementation station requests worktree editing.
- A plan research station requests read-only analysis.
- An audit validation station requests independent review.

The workflow definition does not contain Codex, Grok, Zclaude, or Pi command syntax.

## Local configuration

Store machine-specific harness configuration in:

```text
./.hancho/config.toml
```

The complete `./.hancho/` folder is ignored by Git.

An initial configuration can look like this:

```toml
schema_version = 1
default_harness = "codex"

[harnesses.codex]
adapter = "builtin:codex"
command = "codex"
capabilities = ["read", "edit_worktree", "review"]

[harnesses.pi]
adapter = "./.hancho/harnesses/pi"
command = "pi"
capabilities = ["read", "edit_worktree"]

[routes.build]
implement = "pi"
review = "codex"

[routes.plan]
research = "codex"
draft = "pi"

[routes.audit]
inspect = "pi"
validate = "codex"
```

This format is a design example. The field names are not yet stable.

## Adapter contract

Support built-in adapters for common harnesses and executable adapters for custom harnesses.

Each adapter supports these operations:

- `doctor`: Check that the CLI exists and that required local setup is available.
- `version`: Return the adapter and harness versions.
- `run`: Start one fresh harness session for one station request.

For `run`, Hancho gives the adapter a normalized request with:

- Run, workflow, and station IDs.
- Repository and worktree paths.
- Prompt or instruction file.
- Required capability and authority profile.
- Model override when one exists.
- Session and log paths.
- Time, retry, and resource limits.

The adapter returns:

- A normalized status.
- Harness and adapter identity.
- Session identity.
- Exit information.
- Paths to raw output and error logs.
- A normalized JSON Lines event stream when supported.

The adapter owns harness-specific command flags, input transport, output decoding, and permission mapping. Hancho owns workflow transitions, scope checks, verification, evidence, retries, Git effects, and work-item state.

## Custom Pi example

A local Pi adapter can be an executable file at:

```text
./.hancho/harnesses/pi
```

The adapter can be written in any language. It translates the Hancho request into the installed `pi` command and translates Pi output into the Hancho result contract.

Hancho executes the adapter as a separate process. It does not load custom adapter code into the Elixir virtual machine.

## Safety and evidence

- A custom adapter must never own commit, push, merge, release, or Beadwork closure.
- Hancho must verify the worktree after every harness run.
- Hancho must record the resolved adapter path, command, version, capabilities, and configuration hash in the work-order journal.
- Configuration must contain environment-variable names, not secret values.
- Hancho must show the resolved harness and authority profile before it starts a station.
- A workflow can require two different configured harnesses for implementation and independent review.

## Open questions

- Should adapters receive the run request through standard input or a request file?
- Which normalized JSON Lines events are required in the first protocol version?
- How does Hancho cancel a harness that has child processes?
- Can a custom adapter add capabilities, or must Hancho recognize all capability names?
- How should a user export a safe configuration template without local paths or secrets?
