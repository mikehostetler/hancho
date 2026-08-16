# Epic 03: Repository Discovery, Initialization, and Configuration

## Goal

Let Hancho find one factory unit and create its ignored local control folder safely.

## Depends on

Epic 02.

## Task 3.1: Discover the control repository

Find the Git repository root, current checkout, common Git directory, remote identity, and current branch.

Acceptance criteria:

- A command from a repository subdirectory finds the correct root.
- A command outside Git stops before it creates files.
- A linked worktree is detected and reports both its checkout root and common Git directory.
- Repository paths are normalized before Hancho stores them.

## Task 3.2: Implement `hancho init`

Create the initial `./.hancho/` layout and add the ignore rule.

Acceptance criteria:

- `hancho init` creates `config.toml`, `runs/`, `harnesses/`, `locks/`, and `tmp/` under the repository root.
- The folder has permissions for the current user only where the operating system supports them.
- `.gitignore` contains one effective `.hancho/` rule after repeated calls.
- A second call is safe and does not replace a changed configuration file.

## Task 3.3: Define configuration schema version 1

Define factory settings, workflow selection, harnesses, capabilities, routes, WIP, limits, and environment-variable names.

Acceptance criteria:

- The parser rejects an unknown schema version.
- Validation rejects an unknown workflow, route, harness, or required capability.
- Secret values are not valid configuration fields.
- The resolved configuration has a stable content hash.

## Task 3.4: Implement configuration inspection

Add `hancho config show` and `hancho config validate`.

Acceptance criteria:

- `config show` reports the source of each resolved setting.
- Human and JSON output redact secret values.
- Validation reports all independent errors in one run when practical.
- Validation does not start a harness or change repository state.

## Task 3.5: Implement the first `hancho doctor`

Check Git, the runtime folder, SQLite support, configured harness executables, and workflow routes.

Acceptance criteria:

- Each check reports pass, fail, or warning with a stable name.
- A required failed check gives a nonzero exit status.
- JSON output includes the same check results as human output.
- Doctor does not create work orders or run model prompts.

## Epic exit criteria

- Hancho can initialize and inspect a temporary repository without dirty Git status.
- Invalid local configuration stops work before an external process starts.
