# Hancho: Elixir Factory Driver

Status: Early concept. The product name is confirmed.

## Naming decision

The product name and the command name are `hancho`. The Elixir module namespace is `Hancho`.

The name comes from the Toyota team-leader role. It represents first-line support for operators, standard work, problem response, flow protection, and local Kaizen.

## Intent

Replace `ralph_wiggum_loop_v2.sh` with a local factory driver written in Elixir.

The driver coordinates CLI coding harnesses that perform work in Git repositories. It supports several versioned workflows instead of one fixed loop. Initial workflows include:

- Build.
- Plan.
- Audit.

Each workflow can use a different state machine, authority profile, set of stations, and evidence contract.

Hancho coordinates CLI harness processes only. People provide purpose, policy, approvals, and exception decisions. Hancho does not model people or remote services as harness operators.

## TPS role

The working metaphor is a foreman.

Toyota uses two related shop-floor roles:

- A **team leader**, called **hancho** in Japanese, gives first-line support to a small team. This person responds to Andon calls, protects flow, checks standard work, solves problems, and leads local Kaizen.
- A **group leader** is the first level of management. This person supports several team leaders and has wider supervisory authority.

The factory driver is closer to a **team leader** because it supports operators and controls normal flow. It must not replace the human owner, take disciplinary authority, or change factory purpose and policy by itself.

References:

- [Toyota job titles](https://www.toyota-global.com/company/history_of_toyota/75years/data/company_information/personnel/personnel-related_development/job_titles.html)
- [Lean Enterprise Institute: Team Leader](https://www.lean.org/lexicon-terms/team-leader/)
- [Lean Enterprise Institute: Team Leader and Group Leader roles](https://www.lean.org/the-lean-post/articles/team-leaders-the-engine-of-toyotas-performance/)

## Why Elixir

Elixir supplies the main capabilities that the factory driver needs:

- Explicit state-machine behavior.
- Supervised processes and bounded concurrency.
- External harness control through ports.
- Pattern matching for events, guards, and transitions.
- Strong tests for workflow rules.
- Self-contained releases for local installation.
- Direct alignment with the main target projects.

An active OTP process can operate one workflow run. Durable state must remain outside process memory.

## Core model

Use these terms:

| Term | Meaning |
|---|---|
| Factory Unit | One target Git repository. |
| Workflow | A versioned state machine such as build, plan, or audit. |
| Station | One reusable capability or action in a workflow. |
| Operator | A configured CLI harness that operates a station. |
| Work order | One workflow run. |
| Journal | Durable events, decisions, effects, and evidence for a work order. |
| Andon | A visible stop, abnormal condition, or decision request. |

## Architecture direction

Separate the system into these parts:

- A pure transition engine.
- Versioned workflow definitions.
- A durable run journal.
- A repository-local `.hancho/` folder for machine configuration, durable state, logs, and evidence. See [Hancho local runtime state and logs](hancho-local-runtime-state.md).
- Reusable stations.
- Flexible CLI harness adapters for Grok, Zclaude, Codex, Pi, and later tools. See [Hancho CLI harness adapters and routing](hancho-cli-harnesses.md).
- A Beadwork execution adapter.
- Git worktree, verification, review, and acceptance adapters.
- A command-line interface for run, status, resume, stop, and reconcile operations.

The transition engine receives the current state, an event, and a workflow definition. It returns the new state and requested actions. A separate action runner performs external effects.

## Workflow sketches

```text
Build:
released → implementing → verifying → reviewing → accepting → complete

Plan:
released → researching → drafting → reviewing → approved

Audit:
released → inventory → inspecting → validating → reporting → complete
```

Workflows request capabilities such as read-only analysis, worktree editing, or review. They do not name a specific coding harness. Repository-local configuration assigns a compatible CLI harness to each workflow station.

Each work order pins its workflow name and version. A new workflow version does not silently change an active work order.

## First implementation path

1. Preserve the Bash script as the reference behavior.
2. Create a supervised Elixir application without Phoenix.
3. Implement the pure transition engine and durable journal.
4. Add a fake harness for workflow tests.
5. Implement `Build.V1` and the Grok adapter.
6. Match the current scope, gate, worktree, verification, repair, and receipt controls.
7. Add Zclaude and Codex adapters.
8. Add `Plan.V1` and `Audit.V1` after the build workflow is stable.
