defmodule Hancho.Workflow.IssueSelector do
  @moduledoc "Selects ordered ready tasks behind the Beadwork adapter boundary."

  alias Hancho.Beadwork.Issue
  alias Hancho.Demand.Markers

  @spec select(module(), String.t(), pos_integer()) :: {:ok, [Issue.t()]} | {:error, term()}
  def select(beadwork, repository, count) do
    with {:ok, ready_values} <- beadwork.ready(working_dir: repository),
         {:ok, ready} <- parse_issues(ready_values),
         {:ok, all_values} <- beadwork.list_all(working_dir: repository),
         {:ok, all} <- parse_issues(all_values),
         {:ok, candidates} <- task_candidates(ready, all, count) do
      select_count(candidates, count)
    end
  end

  defp task_candidates(ready, all, count) do
    by_id = Map.new(all, &{&1.id, &1})

    tasks =
      ready
      |> Enum.map(&Map.get(by_id, &1.id, &1))
      |> Enum.filter(&ready_task?(&1, by_id))

    if length(tasks) >= count,
      do: {:ok, tasks},
      else: ready_tasks_from_all(all, by_id)
  end

  defp ready_tasks_from_all(issues, by_id) do
    statuses = Map.new(issues, &{&1.id, &1.status})

    ready =
      issues
      |> Enum.filter(&ready_task?(&1, by_id))
      |> Enum.sort_by(&queue_order/1)
      |> select_serially_ready(statuses)

    {:ok, ready}
  end

  defp parse_issues(values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, issues} ->
      case Issue.new(value) do
        {:ok, issue} -> {:cont, {:ok, [issue | issues]}}
        {:error, reason} -> {:halt, {:error, {:invalid_beadwork_issue, reason}}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      error -> error
    end
  end

  defp parse_issues(value), do: {:error, {:invalid_beadwork_issue_list, value}}

  defp select_count(ready, count) do
    selected = Enum.take(ready, count)

    if length(selected) == count do
      {:ok, selected}
    else
      {:error, "Beadwork has #{length(selected)} ready tasks; #{count} are required."}
    end
  end

  defp select_serially_ready(issues, statuses) do
    {selected, _selected_ids} =
      Enum.reduce(issues, {[], MapSet.new()}, fn issue, {selected, selected_ids} ->
        if blockers_ready?(issue, statuses, selected_ids) do
          {[issue | selected], MapSet.put(selected_ids, issue.id)}
        else
          {selected, selected_ids}
        end
      end)

    Enum.reverse(selected)
  end

  defp blockers_ready?(issue, statuses, selected_ids) do
    Enum.all?(issue.blocked_by, fn blocker ->
      Map.get(statuses, blocker) == "closed" or MapSet.member?(selected_ids, blocker)
    end)
  end

  defp queue_order(issue) do
    ordinal =
      case Regex.run(~r/Queue ordinal: `(\d+)`/, issue.description) do
        [_, value] -> String.to_integer(value)
        nil -> 2_147_483_647
      end

    {ordinal, issue.id}
  end

  defp ready_task?(%Issue{type: "task", status: status} = issue, by_id)
       when status in ["open", "in_progress"] do
    Markers.mapped_task?(issue) and
      issue.parent |> then(&Map.get(by_id, &1)) |> Markers.mapped_epic?()
  end

  defp ready_task?(_issue, _by_id), do: false
end
