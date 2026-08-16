# Epic 02: Elixir Escript Foundation

## Goal

Create the root Mix project, the OTP application, and a small stable command shell.

## Depends on

Epic 01.

## Task 2.1: Create the root Mix project

Add `mix.exs`, `lib/`, `test/`, and project configuration without moving the inbox, plan, or Bash driver.

Acceptance criteria:

- `mix compile --warnings-as-errors` passes.
- `mix test` passes.
- `mix format --check-formatted` passes.
- The application starts a named `Hancho.Supervisor`.

## Task 2.2: Add the escript entry point

Add `Hancho.CLI.main/1` and configure `mix escript.build` to create `hancho`.

Acceptance criteria:

- `./hancho version` prints the application version.
- `./hancho --help` prints command help and exits with status 0.
- An unknown command prints a short error, gives the help command, and exits with a nonzero status.
- The entry point converts expected failures to stable exit codes without a stack trace.

## Task 2.3: Add a command router and output contract

Use a small internal command behavior. Keep argument parsing separate from command execution.

Acceptance criteria:

- Unit tests call command modules without starting an operating-system process.
- Human output goes to standard output and errors go to standard error.
- `--json` output is valid JSON and contains a schema version.
- Non-interactive output has no color or prompts.

## Task 2.4: Add common development checks

Define the checks that every change to Hancho must pass.

Acceptance criteria:

- One documented command runs format, compile with warnings as errors, and tests.
- Test helpers create isolated temporary Git repositories.
- Tests do not use the real user `./.hancho/` folder.
- The generated `hancho` file and test runtime files do not enter Git status.

## Epic exit criteria

- A user can build and run the escript.
- The project has a supervised application and a testable CLI boundary.
- The old Bash driver and all source material remain unchanged.
