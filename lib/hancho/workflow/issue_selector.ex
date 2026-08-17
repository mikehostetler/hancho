defmodule Hancho.Workflow.IssueSelector do
  @moduledoc "Selects ordered ready tasks behind the Beadwork adapter boundary."

  alias Hancho.Beadwork.Issue

  @spec select(module(), String.t(), pos_integer()) :: {:ok, [Issue.t()]} | {:error, term()}
  def select(beadwork, repository, count) do
    with {:ok, ready_values} <- beadwork.ready(working_dir: repository),
         {:ok, ready} <- parse_issues(ready_values),
         {:ok, candidates} <- task_candidates(beadwork, repository, ready, count) do
      select_count(candidates, count)
    end
  end

  defp task_candidates(beadwork, repository, ready, count) do
    tasks = Enum.filter(ready, &ready_task?/1)

    if length(tasks) >= count,
      do: {:ok, tasks},
      else: ready_tasks_from_all(beadwork, repository)
  end

  defp ready_tasks_from_all(beadwork, repository) do
    with {:ok, values} <- beadwork.list_all(working_dir: repository),
         {:ok, issues} <- parse_issues(values) do
      statuses = Map.new(issues, &{&1.id, &1.status})

      ready =
        issues
        |> Enum.filter(&ready_task_from_all?(&1, statuses))
        |> Enum.sort_by(&queue_order/1)

      {:ok, ready}
    end
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
    selected = ready |> Enum.filter(&ready_task?/1) |> Enum.take(count)

    if length(selected) == count do
      {:ok, selected}
    else
      {:error, "Beadwork has #{length(selected)} ready tasks; #{count} are required."}
    end
  end

  defp ready_task_from_all?(issue, statuses) do
    ready_task?(issue) and Enum.all?(issue.blocked_by, &(Map.get(statuses, &1) == "closed"))
  end

  defp queue_order(issue) do
    ordinal =
      case Regex.run(~r/Queue ordinal: `(\d+)`/, issue.description) do
        [_, value] -> String.to_integer(value)
        nil -> 2_147_483_647
      end

    {ordinal, issue.id}
  end

  defp ready_task?(%Issue{type: "task", status: status})
       when status in ["open", "in_progress"],
       do: true

  defp ready_task?(_issue), do: false
end
