# Inbox Review

This review maps each inbox item to a product decision and a build epic. It keeps the inbox as source material. The `plan/` folder is the ordered implementation view.

## 1. Inbox index and external materials

Source: [`../inbox/README.md`](../inbox/README.md)

Decision:

- Treat Compound Engineering, Impeccable, the codebase audit prompt, and Matt Pocock's skills as instruction sources.
- Do not add them as Hancho runtime dependencies.
- Add an instruction-pack interface after the workflow and harness contracts are stable.

Plan location: Epic 11.

## 2. Codebase audit prompt

Source: [`../inbox/codebase-audit-prompt.md`](../inbox/codebase-audit-prompt.md)

Decision:

- Keep the external link as the canonical prompt.
- Make Audit.V1 read-only.
- Give each audit station a bounded ownership area.
- Require coverage checks, finding deduplication, evidence, and explicit skip records.
- Verify that an audit leaves the target repository unchanged.

Plan location: Epic 11.

## 3. Elixir factory driver

Source: [`../inbox/elixir-factory-driver.md`](../inbox/elixir-factory-driver.md)

Decision:

- Build Hancho in Elixir with an OTP supervision tree.
- Package the first version as an escript, not an OTP release.
- Keep the transition engine pure. Put external effects in action modules.
- Use versioned built-in workflows for Build, Plan, and Audit.
- Keep the Bash script as a behavior reference until Build.V1 has parity.

Plan location: Epics 01, 02, 04, 07, and 12.

## 4. GitHub Issues and Beadwork

Source: [`../inbox/github-issues-and-beadwork.md`](../inbox/github-issues-and-beadwork.md)

Decision:

- GitHub Issues are the commitment ledger.
- Beadwork is the execution ledger.
- Hancho stores both references on a work order but does not copy full task lists.
- The first integration uses Beadwork for ready work, claim, and closure.
- GitHub automation can follow after the link format and close policy are fixed.

Plan location: Epic 09.

## 5. CLI experience

Source: [`../inbox/hancho-cli-experience.md`](../inbox/hancho-cli-experience.md)

Decision:

- Start with `init`, `doctor`, `run`, `runs`, `show`, and `logs`.
- Add decisions, resume, cancel, and reconcile after the journal can recover work.
- Add `up`, `down`, `status`, `attach`, and tmux after one-work-order mode is stable.
- A command sends an event. It does not set a workflow state directly.

Plan location: Epics 02, 03, 08, and 10.

## 6. CLI harnesses

Source: [`../inbox/hancho-cli-harnesses.md`](../inbox/hancho-cli-harnesses.md)

Decision:

- Define one versioned request and result protocol.
- Use a fake adapter first and Grok for Bash-driver parity.
- Add Codex and a custom executable adapter next.
- Route by capability and station. Do not put harness names in workflow definitions.
- Keep all Git and work-item effects in Hancho.

Plan location: Epic 06 and Epic 07.

## 7. Local runtime state

Source: [`../inbox/hancho-local-runtime-state.md`](../inbox/hancho-local-runtime-state.md)

Decision:

- Use the repository-root `./.hancho/` folder and ignore the complete folder in Git.
- Use SQLite for state and an append-only event journal.
- Store streams and large artifacts in files. Index them in SQLite.
- Record effect intent before an external effect and its observed result after the effect.
- Make an interrupted effect uncertain until reconciliation proves its result.

Plan location: Epics 03, 05, and 08.

## 8. Personal SDLC factory workflow

Source: [`../inbox/personal-sdlc-factory-workflow.md`](../inbox/personal-sdlc-factory-workflow.md)

Decision:

- One Git repository is one factory unit.
- Use pull, WIP limits, standard work, quality at the source, Jidoka, Andon, and Kaizen as operating rules.
- Start with Elixir library and private Phoenix application quality profiles.
- Keep merge, release, and deployment behind explicit authority and evidence gates.
- Do not include release or deployment effects in Build.V1.

Plan location: Epics 01, 04, 07, 10, and 12.

## Main plan risks

1. A SQLite driver can include native code that is difficult to load from an escript. Epic 01 must prove the package before schema work starts.
2. Process cancellation can leave harness child processes active. Epic 06 must test process-tree shutdown.
3. A crash during a Git or Beadwork effect can make a retry unsafe. Epics 05 and 08 must implement intent, observation, and reconciliation.
4. The full CLI proposal is too large for the walking skeleton. The release sequence delays the continuous host and queue.
5. Built-in workflow modules are easier to validate than user-defined workflows. External workflow authoring is outside the first release.
