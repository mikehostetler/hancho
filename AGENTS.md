# Hancho Agent Instructions

## Product

- Hancho is an Elixir CLI that manages a software factory for one Git repository.
- Build Hancho as an escript.
- Keep logs, configuration, and durable runtime state in a repository-local `.hancho/` folder.

## Technical choices

- Use `jason` for JSON.
- Use `toml_elixir` to read TOML configuration files.
- Use `zoi` to validate configuration data.
- Use the OTP `:gen_statem` behavior for workflow state management.
- Use `erlexec` for operating-system process management.
- Use the `git` package through `Hancho.Git` for Git commands. Run Git processes through erlexec.
- Use `jido_harness` to call and manage all CLI coding agents.
- Open any problem with CLI-agent calls or lifecycle management as an issue in `https://github.com/agentjido/jido_harness/issues`.

## Working rules

- Run `bw prime` before you start work.
- Use Beadwork (`bw`) to keep plans, progress, and decisions in Git.
- Complete Beadwork tasks by committing, closing the task, and running `bw sync`.
- Keep changes small and simple.
- Preserve existing files unless the user asks you to remove them.
- Update the README when you add a file that needs an explanation.
