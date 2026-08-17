defmodule Hancho.Workflow.Inspector do
  @moduledoc "Builds one read-only report from durable workflow state."

  alias Hancho.Workflow.Store

  @spec inspect(Hancho.Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(project, run_id, options \\ []) do
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, store} <- store_api.open(project.bedrock_path) do
      result = inspect_with_store(store_api, store, run_id)

      case store_api.close(store) do
        :ok -> result
        {:error, reason} -> {:error, {:state_flush_failed, reason}}
      end
    end
  end

  defp inspect_with_store(store_api, store, run_id) do
    with {:ok, run} <- store_api.fetch_run(store, run_id),
         {:ok, steps} <- store_api.list_steps(store, run_id),
         {:ok, outputs} <- Jason.decode(run["outputs_json"]) do
      {:ok,
       %{
         run_id: run["id"],
         workflow: run["workflow_name"],
         status: run["status"],
         current_step: run["current_step"],
         started_at: run["started_at"],
         finished_at: run["finished_at"],
         duration_ms: duration(run["started_at"], run["finished_at"]),
         provider: provider_result(outputs),
         verification: verification_result(outputs),
         commit: get_in(outputs, ["land", "commit"]) || get_in(outputs, ["commit", "commit"]),
         retained_worktree: retained_worktree(outputs),
         failure: decode_optional(run["error_json"]),
         steps: Enum.map(steps, &step_report/1)
       }}
    end
  end

  defp provider_result(outputs) do
    case outputs["implement"] do
      nil ->
        nil

      result ->
        Map.take(result, ["provider", "harness_run_id", "status", "text", "text_truncated"])
    end
  end

  defp verification_result(outputs) do
    case outputs["verify"] do
      nil ->
        nil

      result ->
        %{
          exit_status: result["exit_status"],
          summary: verification_summary(result["output"] || ""),
          output_path: result["output_path"]
        }
    end
  end

  defp verification_summary(output) do
    case Regex.scan(~r/^Result:\s*.+$/m, output) |> List.last() do
      [summary] -> summary
      nil -> output |> String.split("\n", trim: true) |> List.last()
    end
  end

  defp retained_worktree(outputs) do
    case {outputs["create_worktree"], outputs["remove_worktree"]} do
      {%{"worktree_path" => path}, nil} -> path
      _other -> nil
    end
  end

  defp step_report(step) do
    %{
      position: step["position"],
      name: step["name"],
      action: step["action"],
      status: step["status"],
      started_at: step["started_at"],
      finished_at: step["finished_at"],
      duration_ms: duration(step["started_at"], step["finished_at"]),
      error: decode_optional(step["error_json"])
    }
  end

  defp duration(nil, _finished_at), do: nil

  defp duration(started_at, finished_at) do
    with {:ok, started, _offset} <- DateTime.from_iso8601(started_at),
         {:ok, finished, _offset} <-
           DateTime.from_iso8601(finished_at || DateTime.to_iso8601(DateTime.utc_now())) do
      DateTime.diff(finished, started, :millisecond)
    else
      _error -> nil
    end
  end

  defp decode_optional(nil), do: nil

  defp decode_optional(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end
end
