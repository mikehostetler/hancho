# Hancho Agent Instructions

## Product

- Hancho is an Elixir CLI that manages a software factory for one Git repository.
- Build Hancho as an escript.
- Keep logs, configuration, and durable runtime state in a repository-local `.hancho/` folder.

## Technical choices

- Use `jason` for JSON.
- Use `Hancho.Log` for normalized factory activity. It uses Elixir Logger and
  the OTP `:logger_std_h` file handler. Keep activity writes ordered and
  durable. Do not add another Logger file-backend package without a new need.
- Use `toml_elixir` to read TOML configuration files.
- Use `yaml_elixir` to read workflow definitions. Keep workflows out of TOML.
- Use `zoi` to validate configuration data.
- Define every Hancho data struct from a `Zoi.struct/3` schema. Expose the
  schema with `schema/0`, derive the type and fields from it, and parse data in
  public constructors.
- Read repository configuration through `Hancho.Config` and use dot-delimited keys.
- Use the OTP `:gen_statem` behavior for workflow state management.
- Use `jido_action` for workflow actions and action parameter validation.
- Keep action module resolution in an explicit allowlist. Do not create atoms
  from YAML action names.
- Store durable workflow and step state in a Bedrock cluster at
  `.hancho/bedrock/`. Keep all Bedrock descriptor, coordinator, log, and storage
  worker files in that repository-local folder. Use atomic transactions for
  state changes and flush the storage window before the CLI exits.
- Keep the first workflow sequential and in the foreground. Stop on the first
  failed step and retain its durable state.
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
