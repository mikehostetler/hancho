defmodule Hancho.PlanRunner do
  @moduledoc "Runs Plan.V1 without changing the target source tree."

  alias Hancho.Harness.Executor
  alias Hancho.Workflow.{Event, Registry}
  alias Hancho.{Artifacts, Config, Error, Git, Journal, JSON, Repository, SQLite, Store}

  @spec run(Repository.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(repository, work_ref, options \\ []) do
    with {:ok, config} <- Config.load(repository),
         {:ok, definition} <- Registry.fetch("plan", 1),
         {:ok, snapshot} <- snapshot(repository),
         {:ok, work_order} <-
           Journal.create_work_order(repository, config, definition, work_ref, %{
             actor: actor(),
             reason: "Plan work order submitted",
             baseline_commit: snapshot.head,
             target_branch: repository.branch
           }),
         {:ok, started} <-
           transition(repository, work_order, definition, "start", "Plan research started"),
         {:ok, research} <-
           station(
             repository,
             config,
             definition,
             started.work_order,
             "research",
             research_prompt(work_ref, options)
           ),
         {:ok, notes} <- write_research(repository, work_order["id"], work_ref, research),
         {:ok, drafting} <-
           transition(
             repository,
             started.work_order,
             definition,
             "research_complete",
             "Research evidence is ready"
           ),
         {:ok, _draft} <-
           station(
             repository,
             config,
             definition,
             drafting.work_order,
             "draft",
             draft_prompt(work_ref, options, notes)
           ),
         {:ok, plan} <- write_plan(repository, work_order["id"], work_ref, options, 1),
         {:ok, reviewing} <-
           transition(
             repository,
             drafting.work_order,
             definition,
             "draft_complete",
             "Bounded plan is ready",
             %{artifacts: ["plan"]}
           ),
         {:ok, reviewed, plan} <-
           review(repository, config, definition, reviewing.work_order, plan, work_ref, options),
         {:ok, waiting} <-
           transition(
             repository,
             reviewed,
             definition,
             "review_accepted",
             "Review accepted the bounded plan",
             %{artifacts: ["plan"]}
           ),
         {:ok, decision} <- request_approval(repository, waiting.work_order, plan),
         :ok <- unchanged(repository, snapshot) do
      {:ok, %{work_order: waiting.work_order, plan: plan, decision: decision}}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  @spec resume(Repository.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(repository, run_id) do
    with {:ok, definition} <- Registry.fetch("plan", 1),
         {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         true <- work_order["state"] == "awaiting_approval",
         {:ok, plan} <- find_plan(repository, run_id),
         {:ok, decision} <- approval(repository, run_id),
         :ok <- approval_matches(decision, plan),
         {:ok, completed} <-
           Journal.transition(
             repository,
             run_id,
             definition,
             %Event{
               name: if(decision["status"] == "approved", do: "approved", else: "rejected"),
               expected_state: "awaiting_approval",
               actor: decision["actor"],
               reason: decision["reason"]
             },
             %{decisions: %{"plan_approval" => decision["status"]}, artifacts: ["plan"]}
           ) do
      {:ok, %{work_order: completed.work_order, plan: plan, decision: decision}}
    else
      false ->
        {:error, error(:plan_not_awaiting_approval, "Plan work order is not awaiting approval.")}

      {:error, error} ->
        {:error, error}
    end
  end

  defp review(repository, config, definition, work_order, plan, work_ref, options) do
    with {:ok, _review} <-
           station(repository, config, definition, work_order, "review", review_prompt(plan)) do
      findings = Keyword.get(options, :review_findings, [])

      if findings == [] do
        {:ok, work_order, plan}
      else
        with {:ok, rework} <-
               transition(
                 repository,
                 work_order,
                 definition,
                 "review_rework",
                 "Review found bounded plan defects"
               ),
             {:ok, _draft} <-
               station(
                 repository,
                 config,
                 definition,
                 rework.work_order,
                 "draft",
                 rework_prompt(findings),
                 attempt: 2
               ),
             {:ok, revised} <-
               write_plan(
                 repository,
                 work_order["id"],
                 work_ref,
                 Keyword.put(options, :resolved_findings, findings),
                 2
               ),
             {:ok, rereviewing} <-
               transition(
                 repository,
                 rework.work_order,
                 definition,
                 "draft_complete",
                 "Reworked plan is ready",
                 %{artifacts: ["plan"]}
               ),
             {:ok, _review} <-
               station(
                 repository,
                 config,
                 definition,
                 rereviewing.work_order,
                 "review",
                 review_prompt(revised),
                 attempt: 2
               ) do
          {:ok, rereviewing.work_order, revised}
        end
      end
    end
  end

  defp station(repository, config, definition, work_order, station, prompt, options \\ []) do
    case Executor.run_station(
           repository,
           config,
           definition,
           work_order,
           station,
           prompt,
           options
         ) do
      {:ok, %{result: %{status: "success"}} = execution} ->
        {:ok, execution}

      {:ok, execution} ->
        {:error,
         error(
           :plan_station_failed,
           "Plan station '#{station}' ended with '#{execution.result.status}'."
         )}

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp write_research(repository, run_id, work_ref, research) do
    Artifacts.write(
      repository,
      run_id,
      "research_notes",
      "research.json",
      JSON.encode!(%{work_ref: work_ref, harness_session: research.result.session_id}),
      media_type: "application/json",
      retention: "evidence"
    )
  end

  defp write_plan(repository, run_id, work_ref, options, revision) do
    goal = Keyword.get(options, :goal, work_ref)

    scope =
      list_option(options, :scope, ["Analyze the admitted request", "Do not change source code"])

    tasks =
      list_option(options, :tasks, [
        "Confirm the goal and boundaries",
        "Implement the bounded work",
        "Run the required checks",
        "Review the result"
      ])

    dependencies =
      list_option(options, :dependencies, ["Repository and required local tools are available"])

    risks = list_option(options, :risks, ["Scope can be incomplete or ambiguous"])

    checks =
      list_option(options, :checks, [
        "Required project checks pass",
        "Repository source remains unchanged during planning"
      ])

    acceptance =
      list_option(options, :acceptance, [
        "Each task is bounded and has a check",
        "The owner approves this exact artifact hash"
      ])

    resolved = list_option(options, :resolved_findings, [])

    markdown = """
    # Plan: #{goal}

    Revision: #{revision}
    Work reference: `#{work_ref}`

    ## Goal

    #{goal}

    ## Scope

    #{bullets(scope)}

    ## Tasks

    #{numbered(tasks)}

    ## Dependencies

    #{bullets(dependencies)}

    ## Risks

    #{bullets(risks)}

    ## Checks

    #{bullets(checks)}

    ## Acceptance criteria

    #{bullets(acceptance)}

    ## Resolved review findings

    #{bullets(if(resolved == [], do: ["None"], else: resolved))}
    """

    if byte_size(markdown) > 32_768 do
      {:error, error(:plan_too_large, "The plan exceeds the 32 KiB evidence limit.")}
    else
      Artifacts.write(repository, run_id, "plan", "plan-v#{revision}.md", markdown,
        media_type: "text/markdown",
        retention: "durable"
      )
    end
  end

  defp request_approval(repository, work_order, plan) do
    Journal.request_decision(repository, work_order["id"], "plan_approval", %{
      artifact_id: plan["id"],
      artifact_hash: plan["content_hash"],
      relative_path: plan["relative_path"]
    })
  end

  defp approval(repository, run_id) do
    with {:ok, rows} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM decisions WHERE run_id = #{SQLite.quote(run_id)} AND kind = 'plan_approval' AND status IN ('approved', 'rejected') ORDER BY decided_at DESC LIMIT 1;"
           ) do
      case rows do
        [decision] ->
          {:ok, decision}

        [] ->
          {:error,
           error(:plan_approval_required, "The exact plan artifact needs an approval decision.")}
      end
    end
  end

  defp approval_matches(%{"status" => "rejected"}, _plan), do: :ok

  defp approval_matches(decision, plan) do
    request = JSON.decode!(decision["request_json"])

    if request["artifact_hash"] == plan["content_hash"] do
      :ok
    else
      {:error,
       error(:plan_approval_stale, "The approval does not name the current plan artifact hash.")}
    end
  end

  defp find_plan(repository, run_id) do
    with {:ok, artifacts} <- Artifacts.list(repository, run_id) do
      case artifacts |> Enum.filter(&(&1["kind"] == "plan")) |> List.last() do
        nil -> {:error, error(:plan_artifact_missing, "The plan artifact is missing.")}
        plan -> {:ok, plan}
      end
    end
  end

  defp snapshot(repository) do
    with {:ok, head} <- Git.command(repository.root, ["rev-parse", "HEAD"]),
         {:ok, status} <-
           Git.command(repository.root, ["status", "--porcelain=v1", "--untracked-files=all"]) do
      {:ok, %{head: String.trim(head), status: status}}
    end
  end

  defp unchanged(repository, before) do
    with {:ok, after_snapshot} <- snapshot(repository) do
      if before == after_snapshot,
        do: :ok,
        else:
          {:error,
           error(:plan_changed_repository, "Plan.V1 changed the target repository tree or HEAD.")}
    end
  end

  defp transition(repository, work_order, definition, event, reason, facts \\ %{}) do
    Journal.transition(
      repository,
      work_order["id"],
      definition,
      %Event{name: event, expected_state: work_order["state"], actor: "hancho", reason: reason},
      facts
    )
  end

  defp research_prompt(work_ref, options),
    do:
      "Research the admitted planning request read-only. Work reference: #{work_ref}. Goal: #{Keyword.get(options, :goal, work_ref)}"

  defp draft_prompt(work_ref, options, notes),
    do:
      "Draft a bounded plan artifact without source edits. Work reference: #{work_ref}. Research evidence: #{notes["content_hash"]}. Goal: #{Keyword.get(options, :goal, work_ref)}"

  defp review_prompt(plan),
    do:
      "Review the exact plan artifact hash #{plan["content_hash"]}. Check goal, scope, tasks, dependencies, risks, checks, and acceptance criteria. Do not edit source code."

  defp rework_prompt(findings),
    do:
      "Rework only these plan review findings: #{JSON.encode!(findings)}. Do not edit source code."

  defp list_option(options, key, default) do
    case Keyword.get(options, key, default) do
      value when is_list(value) -> value
      value -> [to_string(value)]
    end
  end

  defp bullets(values), do: Enum.map_join(values, "\n", &"- #{&1}")

  defp numbered(values),
    do:
      values
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {value, index} -> "#{index}. #{value}" end)

  defp actor, do: System.get_env("USER") || "local-user"
  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
