defmodule Hancho.AuditRunner do
  @moduledoc "Runs bounded, read-only Audit.V1 inspection units and produces an evidence report."

  alias Hancho.Harness.Executor
  alias Hancho.Workflow.{Event, Registry}
  alias Hancho.{Artifacts, Config, Error, Git, Journal, JSON, Repository}

  @spec run(Repository.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(repository, work_ref, options \\ []) do
    with {:ok, config} <- Config.load(repository),
         {:ok, definition} <- Registry.fetch("audit", 1),
         {:ok, snapshot} <- snapshot(repository),
         {:ok, scopes} <- scopes(repository, options),
         :ok <- validate_boundaries(scopes, Keyword.get(options, :overlap_reasons, %{})),
         {:ok, work_order} <-
           Journal.create_work_order(repository, config, definition, work_ref, %{
             actor: actor(),
             reason: "Audit work order submitted",
             baseline_commit: snapshot.head,
             target_branch: repository.branch
           }),
         {:ok, started} <-
           transition(repository, work_order, definition, "start", "Audit inventory started"),
         {:ok, inventory_execution} <-
           station(
             repository,
             config,
             definition,
             started.work_order,
             "inventory",
             inventory_prompt(scopes)
           ),
         {:ok, inventory} <-
           write_inventory(repository, work_order["id"], scopes, inventory_execution),
         {:ok, inspecting} <-
           transition(
             repository,
             started.work_order,
             definition,
             "inventory_complete",
             "Subsystem ownership inventory is ready",
             %{artifacts: ["audit_inventory"]}
           ),
         {:ok, inspections} <-
           inspect_units(repository, config, definition, inspecting.work_order, scopes, options),
         {:ok, validating} <-
           transition(
             repository,
             inspecting.work_order,
             definition,
             "inspection_complete",
             "Bounded inspection evidence is ready",
             %{artifacts: ["inspection_unit"]}
           ),
         {:ok, validation_execution} <-
           station(
             repository,
             config,
             definition,
             validating.work_order,
             "validate",
             validation_prompt(inspections)
           ),
         {:ok, findings, coverage, skips} <-
           validate_findings(
             repository,
             work_order["id"],
             scopes,
             inspections,
             validation_execution,
             options
           ),
         {:ok, reporting} <-
           transition(
             repository,
             validating.work_order,
             definition,
             "validation_complete",
             "Material findings and coverage are validated",
             %{artifacts: ["audit_findings"]}
           ),
         {:ok, report} <-
           write_report(
             repository,
             work_order["id"],
             work_ref,
             inventory,
             findings,
             coverage,
             skips
           ),
         {:ok, completed} <-
           transition(
             repository,
             reporting.work_order,
             definition,
             "report_complete",
             "Audit report is complete",
             %{artifacts: ["audit_report"]}
           ),
         :ok <- unchanged(repository, snapshot) do
      {:ok,
       %{
         work_order: completed.work_order,
         inventory: inventory,
         inspections: inspections,
         findings: findings,
         coverage: coverage,
         report: report
       }}
    end
  end

  defp scopes(repository, options) do
    requested = Keyword.get(options, :audit_scopes)

    scopes =
      if is_list(requested) and requested != [] do
        requested
      else
        repository.root
        |> File.ls!()
        |> Enum.reject(&(&1 in [".git", ".hancho"]))
        |> Enum.sort()
      end

    if scopes == [], do: {:ok, ["."]}, else: {:ok, Enum.map(scopes, &Path.relative_to(&1, "."))}
  rescue
    error -> {:error, error(:audit_inventory_failed, Exception.message(error))}
  end

  defp validate_boundaries(scopes, reasons) do
    overlaps =
      for left <- scopes,
          right <- scopes,
          left < right,
          overlap?(left, right),
          not is_binary(reasons["#{left}|#{right}"]) and
            not is_binary(reasons["#{right}|#{left}"]),
          do: "#{left} overlaps #{right}"

    if overlaps == [] do
      :ok
    else
      {:error,
       error(
         :audit_scope_overlap,
         "Inspection ownership overlaps without a reason: #{Enum.join(overlaps, "; ")}"
       )}
    end
  end

  defp overlap?(left, right) do
    left == right or String.starts_with?(left <> "/", right <> "/") or
      String.starts_with?(right <> "/", left <> "/")
  end

  defp write_inventory(repository, run_id, scopes, execution) do
    units =
      Enum.map(scopes, fn scope ->
        %{
          id: unit_id(scope),
          scope: scope,
          owner: "inspection:#{unit_id(scope)}",
          boundary: "Only paths at or below #{scope}",
          inventory_session: execution.result.session_id
        }
      end)

    Artifacts.write(
      repository,
      run_id,
      "audit_inventory",
      "inventory.json",
      JSON.encode!(%{units: units}),
      media_type: "application/json",
      retention: "durable"
    )
  end

  defp inspect_units(repository, config, definition, work_order, scopes, options) do
    wip = get_in(config.data, ["audit", "wip_limit"]) || 2
    budget = get_in(config.data, ["audit", "evidence_budget_bytes"]) || 65_536
    failed_units = MapSet.new(Keyword.get(options, :failed_units, []))

    results =
      scopes
      |> Enum.with_index(1)
      |> Task.async_stream(
        fn {scope, attempt} ->
          inspect_unit(
            repository,
            config,
            definition,
            work_order,
            scope,
            attempt,
            budget,
            failed_units
          )
        end,
        max_concurrency: wip,
        ordered: true,
        timeout: get_in(config.data, ["limits", "harness_timeout_ms"]) || 900_000,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          %{id: "unit-task-failed", scope: "unknown", status: "failed", error: inspect(reason)}
      end)

    {:ok, results}
  end

  defp inspect_unit(
         repository,
         config,
         definition,
         work_order,
         scope,
         attempt,
         budget,
         failed_units
       ) do
    id = unit_id(scope)

    result =
      if MapSet.member?(failed_units, scope) do
        {:error, error(:simulated_inspection_failure, "Inspection unit was stopped for a test.")}
      else
        station(
          repository,
          config,
          definition,
          work_order,
          "inspect",
          inspection_prompt(id, scope, budget),
          attempt: attempt
        )
      end

    data =
      case result do
        {:ok, execution} ->
          %{
            id: id,
            scope: scope,
            status: "complete",
            harness_session: execution.result.session_id,
            evidence_budget_bytes: budget
          }

        {:error, failure} ->
          %{
            id: id,
            scope: scope,
            status: "failed",
            harness_session: nil,
            evidence_budget_bytes: budget,
            error: Exception.message(failure)
          }
      end

    {:ok, artifact} =
      Artifacts.write(
        repository,
        work_order["id"],
        "inspection_unit",
        "#{id}.json",
        JSON.encode!(data),
        media_type: "application/json",
        retention: "evidence"
      )

    Map.put(data, :artifact_hash, artifact["content_hash"])
  end

  defp validate_findings(repository, run_id, scopes, inspections, execution, options) do
    supplied = Keyword.get(options, :findings, [])

    failure_findings =
      inspections
      |> Enum.filter(&(&1.status == "failed"))
      |> Enum.map(fn unit ->
        %{
          title: "Inspection coverage failed for #{unit.scope}",
          evidence: unit.error,
          priority: "high",
          scope: unit.scope,
          material: true
        }
      end)

    findings =
      (supplied ++ failure_findings)
      |> Enum.map(&normalize_finding/1)
      |> Enum.filter(&(&1.material == true and &1.evidence != "" and &1.title != ""))
      |> Enum.uniq_by(&{&1.title, &1.evidence, &1.scope})
      |> Enum.sort_by(&{priority_rank(&1.priority), &1.scope, &1.title})

    covered = inspections |> Enum.filter(&(&1.status == "complete")) |> Enum.map(& &1.scope)
    missing = scopes -- covered
    coverage = %{expected: scopes, covered: covered, missing: missing, complete: missing == []}
    skips = Keyword.get(options, :skip_decisions, [])

    payload = %{
      findings: findings,
      coverage: coverage,
      skips: skips,
      validator_session: execution.result.session_id,
      duplicate_policy: "same title, evidence, and scope",
      weak_finding_policy: "material finding with non-empty evidence"
    }

    with {:ok, _artifact} <-
           Artifacts.write(
             repository,
             run_id,
             "audit_findings",
             "validated-findings.json",
             JSON.encode!(payload),
             media_type: "application/json",
             retention: "durable"
           ) do
      {:ok, findings, coverage, skips}
    end
  end

  defp write_report(repository, run_id, work_ref, inventory, findings, coverage, skips) do
    finding_text =
      if findings == [] do
        "- No material findings."
      else
        Enum.map_join(findings, "\n", fn finding ->
          "- **#{String.upcase(finding.priority)}** `#{finding.scope}` — #{finding.title}\n  Evidence: #{finding.evidence}"
        end)
      end

    skip_text = if skips == [], do: "- None.", else: Enum.map_join(skips, "\n", &"- #{&1}")

    markdown = """
    # Codebase audit: #{work_ref}

    Canonical method: https://gist.github.com/aarondfrancis/8735edbe48532f97ee5ea818db4dbd47

    ## Inventory and ownership

    Inventory artifact: `#{inventory["content_hash"]}`

    #{Enum.map_join(coverage.expected, "\n", &"- `#{&1}` has one bounded inspection owner.")}

    ## Coverage

    - Covered: #{Enum.join(coverage.covered, ", ")}
    - Missing: #{if coverage.missing == [], do: "none", else: Enum.join(coverage.missing, ", ")}
    - Complete: #{coverage.complete}

    ## Validated findings

    #{finding_text}

    ## Explicit skip decisions

    #{skip_text}
    """

    Artifacts.write(repository, run_id, "audit_report", "audit.md", markdown,
      media_type: "text/markdown",
      retention: "durable"
    )
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
           :audit_station_failed,
           "Audit station '#{station}' ended with '#{execution.result.status}'."
         )}

      {:error, failure} ->
        {:error, failure}
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
           error(
             :audit_changed_repository,
             "Audit.V1 changed the target repository tree or HEAD."
           )}
    end
  end

  defp normalize_finding(finding) when is_map(finding) do
    %{
      title: to_string(finding[:title] || finding["title"] || ""),
      evidence: to_string(finding[:evidence] || finding["evidence"] || ""),
      priority: normalize_priority(finding[:priority] || finding["priority"]),
      scope: to_string(finding[:scope] || finding["scope"] || "unknown"),
      material: (finding[:material] || finding["material"]) == true
    }
  end

  defp normalize_finding(_finding),
    do: %{title: "", evidence: "", priority: "low", scope: "unknown", material: false}

  defp normalize_priority(value) when value in ["critical", "high", "medium", "low"], do: value
  defp normalize_priority(_value), do: "medium"
  defp priority_rank("critical"), do: 0
  defp priority_rank("high"), do: 1
  defp priority_rank("medium"), do: 2
  defp priority_rank(_value), do: 3

  defp unit_id(scope),
    do:
      "unit-" <>
        (:crypto.hash(:sha256, scope) |> Base.encode16(case: :lower) |> binary_part(0, 12))

  defp inventory_prompt(scopes),
    do:
      "Inventory these exact non-overlapping repository boundaries read-only: #{Enum.join(scopes, ", ")}. Record ownership and do not edit files."

  defp inspection_prompt(id, scope, budget),
    do:
      "Inspect unit #{id}. Exact scope: #{scope}. Evidence budget: #{budget} bytes. Report only material findings with exact evidence. Do not inspect another unit or edit files."

  defp validation_prompt(inspections),
    do:
      "Validate bounded audit evidence. Remove duplicates and weak findings. Report missing coverage before completion. Units: #{JSON.encode!(inspections)}"

  defp actor, do: System.get_env("USER") || "local-user"
  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
