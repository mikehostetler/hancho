# Hancho acceptance matrix

This matrix is the completion record for the plan. `Pass` means the implementation exists and its automated test or named manual proof passed on the main development system.

| Task | Status | Proof |
|---|---|---|
| 1.1 Domain contract | Pass | `docs/domain-contract.md` |
| 1.2 First release boundary | Pass | `docs/v0.1-scope.md` |
| 1.3 Escript and OTP proof | Pass | `test/hancho/escript_acceptance_test.exs`, `lib/hancho/application.ex` |
| 1.4 SQLite escript proof | Pass | `test/hancho/escript_acceptance_test.exs`, `docs/adr/0002-sqlite-cli.md` |
| 1.5 Reference-driver invariants | Pass | `docs/ralph-parity-checklist.md` |
| 2.1 Root Mix project | Pass | `mix.exs`, `mix check` |
| 2.2 Escript entry point | Pass | `lib/hancho/cli.ex`, `test/hancho/escript_acceptance_test.exs` |
| 2.3 Command and output contract | Pass | `lib/hancho/cli/`, `test/hancho/cli_test.exs` |
| 2.4 Development checks | Pass | `mix.exs`, `test/support/repository_case.ex`, `.gitignore` |
| 3.1 Repository discovery | Pass | `lib/hancho/repository.ex`, `test/hancho/repository_test.exs` |
| 3.2 Repository initialization | Pass | `lib/hancho/repository.ex`, `test/hancho/repository_test.exs` |
| 3.3 Configuration schema | Pass | `lib/hancho/config.ex`, `test/hancho/config_test.exs` |
| 3.4 Configuration inspection | Pass | `lib/hancho/cli/commands/config.ex`, `test/hancho/config_test.exs` |
| 3.5 Doctor command | Pass | `lib/hancho/doctor.ex`, `test/hancho/doctor_test.exs` |
| 4.1 Workflow data | Pass | `lib/hancho/workflow/`, `test/hancho/workflow/definition_test.exs` |
| 4.2 Pure transition function | Pass | `lib/hancho/workflow/engine.ex`, `test/hancho/workflow/engine_test.exs` |
| 4.3 Guards and evidence | Pass | `lib/hancho/workflow/engine.ex`, `test/hancho/workflow/engine_test.exs` |
| 4.4 Workflow registry | Pass | `lib/hancho/workflow/registry.ex`, `test/hancho/cli_test.exs` |
| 4.5 Walking-skeleton workflow | Pass | `lib/hancho/workflows/walking_skeleton/v1.ex`, `test/hancho/runner_test.exs` |
| 5.1 Database migrations | Pass | `lib/hancho/store.ex`, `test/hancho/store_test.exs` |
| 5.2 Append-only journal | Pass | `lib/hancho/journal.ex`, `test/hancho/journal_test.exs` |
| 5.3 Action and effect records | Pass | `lib/hancho/journal.ex`, `test/hancho/reconciler_test.exs` |
| 5.4 Artifact storage | Pass | `lib/hancho/artifacts.ex`, `test/hancho/artifacts_test.exs` |
| 5.5 Read models | Pass | `lib/hancho/read_model.ex`, `test/hancho/cli_test.exs`, `test/hancho/factory_controller_test.exs` |
| 6.1 Harness protocol | Pass | `lib/hancho/harness/protocol.ex`, `test/hancho/harness/protocol_test.exs` |
| 6.2 Adapter behavior and fake | Pass | `lib/hancho/harness/fake.ex`, `test/hancho/harness/fake_test.exs` |
| 6.3 External adapters | Pass | `lib/hancho/harness/external.ex`, `test/hancho/harness/external_test.exs` |
| 6.4 Process limits and cancel | Pass | `lib/hancho/harness/process_runner.ex`, `test/hancho/harness/process_runner_test.exs` |
| 6.5 Routing and inspection | Pass | `lib/hancho/harness/router.ex`, `test/hancho/harness/router_test.exs` |
| 6.6 Real harness adapter | Pass | `lib/hancho/harness/grok.ex`, `lib/hancho/harness/codex.ex`, their contract tests |
| 7.1 Git preflight and worktrees | Pass | `lib/hancho/git.ex`, `test/hancho/git_test.exs` |
| 7.2 Admitted scope | Pass | `lib/hancho/git.ex`, `test/hancho/build_runner_test.exs` |
| 7.3 Gates and authority | Pass | `lib/hancho/gates.ex`, `test/hancho/gates_test.exs`, `test/hancho/build_runner_test.exs` |
| 7.4 Elixir verification | Pass | `lib/hancho/verification.ex`, `test/hancho/verification_test.exs` |
| 7.5 Bounded repair | Pass | `lib/hancho/build_runner.ex`, `test/hancho/build_runner_test.exs` |
| 7.6 Candidate and receipt | Pass | `lib/hancho/build_runner.ex`, `test/hancho/build_runner_test.exs` |
| 7.7 Independent review | Pass | `lib/hancho/build_runner.ex`, `test/hancho/build_runner_test.exs` |
| 8.1 Work-order commands | Pass | `lib/hancho/cli/commands/`, `test/hancho/cli_test.exs` |
| 8.2 Event and raw logs | Pass | `lib/hancho/cli/commands/logs.ex`, `test/hancho/factory_cli_test.exs` |
| 8.3 Durable decisions | Pass | `lib/hancho/operations.ex`, `test/hancho/journal_test.exs` |
| 8.4 Cancel and resume | Pass | `lib/hancho/operations.ex`, `test/hancho/operations_test.exs` |
| 8.5 Effect reconciliation | Pass | `lib/hancho/reconciler.ex`, `test/hancho/reconciler_test.exs` |
| 8.6 Exit codes and schemas | Pass | `docs/cli-exit-codes.md`, `test/hancho/cli_test.exs` |
| 9.1 Work-reference policy | Pass | `docs/work-record-policy.md` |
| 9.2 Work-reference data | Pass | `lib/hancho/work_records.ex`, `test/hancho/work_records_test.exs` |
| 9.3 Beadwork adapter | Pass | `lib/hancho/work_source/beadwork.ex`, its contract test |
| 9.4 GitHub adapter | Pass | `lib/hancho/work_source/github.ex`, its contract test |
| 9.5 Ready-work selection | Pass | `lib/hancho/work_source/beadwork.ex`, `test/hancho/work_source/beadwork_test.exs`, factory release test |
| 9.6 Discovered-work limits | Pass | `lib/hancho/work_records.ex`, `test/hancho/work_records_test.exs` |
| 10.1 Factory controller | Pass | `lib/hancho/factory/controller.ex`, `test/hancho/factory_controller_test.exs` |
| 10.2 Scheduler and WIP | Pass | `lib/hancho/factory/store.ex`, `test/hancho/reliability_test.exs` |
| 10.3 Foreground factory | Pass | `lib/hancho/cli/commands/up.ex`, `test/hancho/escript_acceptance_test.exs` |
| 10.4 Control commands | Pass | `lib/hancho/cli/commands/factory_control.ex`, factory tests |
| 10.5 tmux host | Pass | `lib/hancho/host/tmux.ex`, `test/hancho/host_tmux_test.exs` |
| 10.6 Controller recovery | Pass | `test/hancho/factory_controller_test.exs`, `test/hancho/reliability_test.exs` |
| 11.1 Plan.V1 | Pass | `lib/hancho/plan_runner.ex`, `test/hancho/plan_runner_test.exs` |
| 11.2 Audit.V1 | Pass | `lib/hancho/audit_runner.ex`, `test/hancho/audit_runner_test.exs` |
| 11.3 Bounded audit fan-out | Pass | `lib/hancho/audit_runner.ex`, `test/hancho/audit_runner_test.exs` |
| 11.4 Instruction packs | Pass | `lib/hancho/instruction_packs.ex`, `test/hancho/instruction_packs_test.exs` |
| 11.5 Guidance mappings | Pass | `lib/hancho/instruction_packs.ex`, `test/hancho/instruction_packs_test.exs` |
| 11.6 More harness adapters | Pass | `docs/harness-adapters.md`, adapter and routing tests |
| 12.1 Candidate publication | Pass | `lib/hancho/publication.ex`, `test/hancho/publication_delivery_test.exs` |
| 12.2 Pull request effects | Pass | `lib/hancho/pull_request.ex`, `test/hancho/publication_delivery_test.exs` |
| 12.3 Guarded merge | Pass | `lib/hancho/merge.ex`, `test/hancho/publication_delivery_test.exs` |
| 12.4 Delivery adapters | Pass | `lib/hancho/delivery/`, `test/hancho/publication_delivery_test.exs` |
| 12.5 Observation and closure | Pass | `lib/hancho/closure.ex`, `test/hancho/publication_delivery_test.exs` |
| 13.1 Security and redaction | Pass | `lib/hancho/redactor.ex`, `test/hancho/security_cleanup_test.exs` |
| 13.2 Retention and cleanup | Pass | `lib/hancho/cleanup.ex`, `test/hancho/security_cleanup_test.exs` |
| 13.3 Reliability and compatibility | Pass | reliability, process, fixture, and escript acceptance tests |
| 13.4 Package and install | Pass | `scripts/`, `docs/install-and-upgrade.md`, escript acceptance tests |
| 13.5 Ralph parity and retirement | Pass | `docs/ralph-parity-checklist.md`, `docs/ralph-migration-guide.md` |
| 13.6 Measures and Kaizen | Pass | `lib/hancho/measures.ex`, `lib/hancho/kaizen.ex`, their tests |

## Release checks

Run these checks from the repository root:

```sh
mix check
./scripts/build-release.sh
shasum -a 256 -c hancho.sha256
```

The optional real-model and network tests stay outside the default suite.

## Local real-repository proof

On 2026-08-16, the built `hancho` escript initialized this repository, passed `doctor`, validated `walking_skeleton.v1` and its routes, and completed work order `run-nf58qkgcdf0u` for work reference `release-proof`. The Ralph script was not used. The evidence is in the ignored local `./.hancho/` state.
