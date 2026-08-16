# Hancho operating guide

Hancho is the default local software-factory driver for this repository.

## Start

```sh
hancho init
hancho doctor
hancho up
```

Use `hancho up --tmux` for a detached factory. Use `hancho attach`, `hancho status`, and `hancho logs --follow` to observe it.

Submit one work order with `hancho run WORKFLOW WORK_REF`. Add `--detach` to submit it to an active factory and return after durable queue acceptance.

## Stops and recovery

`hancho pause` stops new releases but keeps active evidence. `hancho down` requests a safe stop. `hancho down --force` records a forced stop request before termination when possible.

After an interrupted action or external-effect window, startup becomes unhealthy and does not release work. Use `hancho status`, inspect the run with `hancho show`, and run `hancho reconcile RUN_ID`. Do not retry an uncertain push, pull request, merge, issue update, delivery, or closure until Hancho observes the external state.

## Evidence and cleanup

Normal logs are redacted. Raw-log views still carry a sensitive-data warning. `hancho cleanup` is a dry-run. `hancho cleanup --apply` removes only expired, non-active, non-uncertain artifacts and records each removal.

Use `hancho measures` for workflow improvement. Do not use the measures to rank people or reward code volume. Approve a standard-work proposal before evaluation. Active work stays pinned to its original workflow version.
