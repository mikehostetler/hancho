defmodule Hancho.Demands do
  @moduledoc "Combines GitHub commitments with Beadwork execution records."

  alias Hancho.Beadwork.Issue, as: BeadworkIssue
  alias Hancho.Demand.{Finding, Markers, Record}

  @spec list(Hancho.Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list(project, source \\ "all", options \\ [])

  def list(project, source, options) when source in ["all", "github", "beadwork"] do
    with {:ok, snapshot} <- snapshot(project, options) do
      records =
        case source do
          "github" -> Enum.reject(snapshot.records, &is_nil(&1.github_url))
          "beadwork" -> Enum.reject(snapshot.records, &is_nil(&1.beadwork_id))
          "all" -> snapshot.records
        end

      {:ok, %{repository: snapshot.repository, source: source, records: records}}
    end
  end

  def list(_project, source, _options), do: {:error, {:invalid_demand_source, source}}

  @spec audit(Hancho.Project.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def audit(project, options \\ []) do
    with {:ok, snapshot} <- snapshot(project, options) do
      {:ok,
       %{repository: snapshot.repository, findings: snapshot.findings, records: snapshot.records}}
    end
  end

  @spec sync(Hancho.Project.t(), :dry_run | :apply, keyword()) :: {:ok, map()} | {:error, term()}
  def sync(project, mode, options \\ [])

  def sync(project, :dry_run, options) do
    with {:ok, snapshot} <- snapshot(project, options),
         :ok <- no_fatal_findings(snapshot.findings) do
      {:ok, %{mode: :dry_run, actions: planned_actions(snapshot), records: snapshot.records}}
    end
  end

  def sync(project, :apply, options) do
    lease = Keyword.get(options, :lease_api, Hancho.FactoryLease)
    lease_options = Keyword.put_new(options, :lease_command, "demands sync")

    lease.with_lease(project, lease_options, fn -> do_sync(project, options) end)
  end

  defp do_sync(project, options) do
    cache = Keyword.get(options, :cache, Hancho.Demand.Cache)

    with {:ok, initial} <- snapshot(project, options),
         :ok <- no_fatal_findings(initial.findings),
         intent_actions = planned_actions(initial),
         :ok <- cache.intent(project, initial.repository, intent_actions),
         {:ok, root_actions} <- apply_roots(project, initial, options),
         {:ok, after_roots} <- snapshot(project, options),
         :ok <- no_fatal_findings(after_roots.findings),
         {:ok, task_actions} <- apply_tasks(project, after_roots, options),
         {:ok, final} <- snapshot(project, options),
         :ok <- mappings_complete(final.records),
         actions = root_actions ++ task_actions,
         :ok <- cache.receipt(project, final.repository, final.records, actions) do
      {:ok, %{mode: :apply, actions: actions, records: final.records}}
    end
  end

  @spec snapshot(Hancho.Project.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def snapshot(project, options \\ []) do
    github = Keyword.get(options, :github, Hancho.GitHub)
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    github_options = adapter_options(project, options, :github)
    beadwork_options = adapter_options(project, options, :beadwork)

    with {:ok, %{repository: repository, issues: github_issues}} <-
           github.list_open(github_options),
         {:ok, beadwork_values} <- beadwork.list_all(beadwork_options),
         {:ok, beadwork_issues} <- parse_beadwork(beadwork_values) do
      {records, findings} = build(repository, github_issues, beadwork_issues)

      {:ok,
       %{repository: repository, records: records, findings: findings, github: github_issues}}
    end
  end

  defp build(repository, github_issues, beadwork_issues) do
    github_by_node = Map.new(github_issues, &{&1.node_id, &1})
    beadwork_by_id = Map.new(beadwork_issues, &{&1.id, &1})

    beadwork_by_url =
      Enum.reduce(beadwork_issues, %{}, fn issue, index ->
        Enum.reduce(
          Markers.github_urls(issue),
          index,
          &Map.update(&2, &1, [issue], fn values -> [issue | values] end)
        )
      end)

    github_records =
      Enum.map(github_issues, fn issue ->
        declared_ids = Markers.beadwork_ids(issue)

        candidates =
          (Map.get(beadwork_by_url, issue.url, []) ++
             Enum.map(declared_ids, &Map.get(beadwork_by_id, &1)))
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq_by(& &1.id)

        cond do
          length(declared_ids) > 1 ->
            new_record(issue, nil, "duplicate", [
              "GitHub contains multiple Beadwork markers: #{Enum.join(declared_ids, ", ")}."
            ])

          length(declared_ids) == 1 and not Map.has_key?(beadwork_by_id, hd(declared_ids)) ->
            new_record(issue, nil, "invalid", [
              "GitHub points to unknown Beadwork record #{hd(declared_ids)}."
            ])

          true ->
            record_for(issue, candidates, github_by_node, beadwork_by_url)
        end
      end)

    mapped_ids =
      github_records |> Enum.map(& &1.beadwork_id) |> Enum.reject(&is_nil/1) |> MapSet.new()

    orphans =
      beadwork_issues
      |> Enum.filter(
        &(&1.status in ["open", "in_progress"] and not MapSet.member?(mapped_ids, &1.id))
      )
      |> Enum.map(&orphan_record(repository, &1))

    records = github_records ++ orphans

    findings =
      Enum.flat_map(records, &record_findings/1) ++
        nesting_findings(github_issues, github_by_node)

    {Enum.sort_by(records, &record_order/1), findings}
  end

  defp record_for(issue, [], _github_by_node, _beadwork_by_url) do
    new_record(issue, nil, "missing", ["No Beadwork record maps to this GitHub Issue."])
  end

  defp record_for(issue, candidates, _github_by_node, _beadwork_by_url)
       when length(candidates) > 1 do
    ids = Enum.map_join(candidates, ", ", & &1.id)

    new_record(issue, nil, "duplicate", [
      "Multiple Beadwork records map to this GitHub Issue: #{ids}."
    ])
  end

  defp record_for(issue, [beadwork], github_by_node, beadwork_by_url) do
    expected_type = if issue.parent_node_id, do: "task", else: "epic"
    problems = []

    problems =
      if beadwork.type == expected_type,
        do: problems,
        else: ["Expected Beadwork type #{expected_type}, found #{beadwork.type}." | problems]

    problems =
      marker_problem(Markers.github_urls(beadwork), issue.url, "Beadwork GitHub URL", problems)

    problems =
      marker_problem(
        Markers.github_nodes(beadwork),
        issue.node_id,
        "Beadwork GitHub node",
        problems
      )

    problems =
      marker_problem(Markers.beadwork_ids(issue), beadwork.id, "GitHub Beadwork", problems)

    problems =
      if issue.parent_node_id do
        parent = Map.get(github_by_node, issue.parent_node_id)
        parent_epics = if parent, do: Map.get(beadwork_by_url, parent.url, []), else: []

        if length(parent_epics) == 1 and beadwork.parent == hd(parent_epics).id do
          problems
        else
          ["Beadwork task is not parented to the mapped Beadwork epic." | problems]
        end
      else
        if is_nil(beadwork.parent),
          do: problems,
          else: ["Mapped Beadwork epic must not have a parent." | problems]
      end

    status = if problems == [], do: "mapped", else: "invalid"
    new_record(issue, beadwork, status, Enum.reverse(problems))
  end

  defp new_record(issue, beadwork, status, problems) do
    Record.new!(%{
      kind: if(issue.parent_node_id, do: "task", else: "epic"),
      title: issue.title,
      github_repository: issue.repository,
      github_node_id: issue.node_id,
      github_number: issue.number,
      github_url: issue.url,
      github_status: issue.state,
      github_parent_node_id: issue.parent_node_id,
      beadwork_id: beadwork && beadwork.id,
      beadwork_status: beadwork && beadwork.status,
      beadwork_parent_id: beadwork && beadwork.parent,
      mapping_status: status,
      problems: problems
    })
  end

  defp orphan_record(repository, issue) do
    Record.new!(%{
      kind: issue.type,
      title: issue.title || issue.id,
      github_repository: repository,
      beadwork_id: issue.id,
      beadwork_status: issue.status,
      beadwork_parent_id: issue.parent,
      mapping_status: "unmapped",
      problems: ["Open Beadwork record has no matching open GitHub demand."]
    })
  end

  defp record_findings(%Record{mapping_status: "mapped"}), do: []

  defp record_findings(record) do
    safe_backlink_problem? = fn problem -> String.starts_with?(problem, "Missing canonical") end

    severity =
      if record.mapping_status == "duplicate" or
           (record.mapping_status == "invalid" and
              not Enum.all?(record.problems, safe_backlink_problem?)),
         do: "error",
         else: "warning"

    identity = record.github_url || record.beadwork_id

    Enum.map(record.problems, fn message ->
      Finding.new!(%{
        severity: severity,
        code: record.mapping_status,
        identity: identity,
        message: message
      })
    end)
  end

  defp nesting_findings(issues, by_node) do
    issues
    |> Enum.filter(fn issue ->
      issue.parent_node_id && Map.get(by_node, issue.parent_node_id) && issue.child_count > 0
    end)
    |> Enum.map(fn issue ->
      Finding.new!(%{
        severity: "error",
        code: "nested_sub_issue",
        identity: issue.url,
        message: "The first version supports only one GitHub sub-issue level."
      })
    end)
  end

  defp planned_actions(snapshot) do
    snapshot.records
    |> Enum.flat_map(fn
      %Record{github_url: nil} ->
        []

      %Record{mapping_status: "missing", kind: kind, github_url: url} ->
        ["create Beadwork #{kind} for #{url} and add both backlinks"]

      %Record{mapping_status: "invalid", problems: problems, github_url: url} ->
        if Enum.all?(problems, &String.contains?(&1, "canonical")),
          do: ["repair backlinks for #{url}"],
          else: []

      _ ->
        []
    end)
  end

  defp apply_roots(project, snapshot, options) do
    apply_records(
      project,
      Enum.filter(snapshot.github, &is_nil(&1.parent_node_id)),
      snapshot.records,
      options
    )
  end

  defp apply_tasks(project, snapshot, options) do
    apply_records(
      project,
      Enum.filter(snapshot.github, &is_binary(&1.parent_node_id)),
      snapshot.records,
      options
    )
  end

  defp apply_records(project, issues, records, options) do
    Enum.reduce_while(issues, {:ok, []}, fn issue, {:ok, actions} ->
      record = Enum.find(records, &(&1.github_node_id == issue.node_id))

      case apply_record(project, issue, record, records, options) do
        {:ok, new_actions} -> {:cont, {:ok, actions ++ new_actions}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_record(_project, _issue, %Record{mapping_status: "mapped"}, _records, _options),
    do: {:ok, []}

  defp apply_record(project, issue, %Record{mapping_status: "missing"}, records, options) do
    parent =
      if issue.parent_node_id do
        records
        |> Enum.find(&(&1.github_node_id == issue.parent_node_id))
        |> then(&(&1 && &1.beadwork_id))
      end

    if issue.parent_node_id && is_nil(parent) do
      {:error, {:missing_parent_mapping, issue.url}}
    else
      beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
      github = Keyword.get(options, :github, Hancho.GitHub)
      type = if issue.parent_node_id, do: "task", else: "epic"
      description = mapping_description(issue)

      with {:ok, value} <-
             beadwork.create(
               issue.title,
               type,
               description,
               parent,
               adapter_options(project, options, :beadwork)
             ),
           {:ok, created} <- BeadworkIssue.new(value),
           {:ok, _comment} <-
             github.comment(
               issue,
               Markers.github_text(issue, created.id),
               adapter_options(project, options, :github)
             ) do
        {:ok, ["created #{created.id} for #{issue.url}", "linked #{issue.url} to #{created.id}"]}
      end
    end
  end

  defp apply_record(
         project,
         issue,
         %Record{mapping_status: "invalid", beadwork_id: id, problems: problems},
         _records,
         options
       ) do
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    github = Keyword.get(options, :github, Hancho.GitHub)
    safe? = Enum.all?(problems, &String.starts_with?(&1, "Missing canonical"))

    if safe? do
      missing_beadwork? =
        Enum.any?(problems, &String.starts_with?(&1, "Missing canonical Beadwork"))

      missing_github? =
        Enum.any?(problems, &String.starts_with?(&1, "Missing canonical GitHub"))

      with {:ok, beadwork_actions} <-
             maybe_add_beadwork_backlink(
               missing_beadwork?,
               beadwork,
               id,
               issue,
               project,
               options
             ),
           {:ok, github_actions} <-
             maybe_add_github_backlink(
               missing_github?,
               github,
               id,
               issue,
               project,
               options
             ) do
        {:ok, beadwork_actions ++ github_actions}
      end
    else
      {:error, {:unsafe_mapping_repair, issue.url, problems}}
    end
  end

  defp apply_record(_project, issue, record, _records, _options),
    do: {:error, {:cannot_sync_mapping, issue.url, record.mapping_status}}

  defp mapping_description(issue) do
    "Managed execution record for GitHub demand.\n\n#{Markers.beadwork_text(issue)}"
  end

  defp marker_problem([expected], expected, _label, problems), do: problems

  defp marker_problem([], _expected, label, problems),
    do: ["Missing canonical #{label} marker." | problems]

  defp marker_problem(values, expected, label, problems),
    do: ["Conflicting #{label} markers #{inspect(values)}; expected #{expected}." | problems]

  defp maybe_add_beadwork_backlink(false, _beadwork, _id, _issue, _project, _options),
    do: {:ok, []}

  defp maybe_add_beadwork_backlink(true, beadwork, id, issue, project, options) do
    case beadwork.comment(
           id,
           Markers.beadwork_text(issue),
           adapter_options(project, options, :beadwork)
         ) do
      {:ok, _} -> {:ok, ["added Beadwork backlink for #{issue.url}"]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_add_github_backlink(false, _github, _id, _issue, _project, _options),
    do: {:ok, []}

  defp maybe_add_github_backlink(true, github, id, issue, project, options) do
    case github.comment(
           issue,
           Markers.github_text(issue, id),
           adapter_options(project, options, :github)
         ) do
      {:ok, _} -> {:ok, ["added GitHub backlink for #{id}"]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp no_fatal_findings(findings) do
    errors = Enum.filter(findings, &(&1.severity == "error"))
    if errors == [], do: :ok, else: {:error, {:demand_mapping_conflicts, errors}}
  end

  defp mappings_complete(records) do
    incomplete = Enum.filter(records, &(&1.github_url && &1.mapping_status != "mapped"))
    if incomplete == [], do: :ok, else: {:error, {:demand_sync_incomplete, incomplete}}
  end

  defp parse_beadwork(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, issues} ->
      case BeadworkIssue.new(value) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, reason} -> {:halt, {:error, {:invalid_beadwork_issue, reason}}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp adapter_options(project, options, name) do
    key = if name == :github, do: :github_options, else: :beadwork_options
    specific = Keyword.get(options, key, [])
    Keyword.put_new(specific, :working_dir, project.root)
  end

  defp record_order(record), do: {record.github_number || 2_147_483_647, record.beadwork_id || ""}
end
