defmodule Hancho.Workflow.QueueReporter do
  @moduledoc "Reports queue state and delivers non-controlling progress and audit events."

  alias Hancho.Workflow.QueueResult

  @spec result(module(), term(), String.t(), String.t()) ::
          {:ok, QueueResult.t()} | {:error, term()}
  def result(store_api, store, queue_id, workflow) do
    with {:ok, queue} <- store_api.fetch_queue(store, queue_id) do
      completed_count = Enum.count(queue["items"], &(&1["status"] == "completed"))
      current = Enum.at(queue["items"], queue["current_position"])

      QueueResult.new(%{
        queue_id: queue_id,
        workflow: workflow,
        status: String.to_existing_atom(queue["status"]),
        completed_count: completed_count,
        total_count: length(queue["items"]),
        current_issue: if(current, do: current["issue_id"]),
        child_runs: Enum.map(queue["items"], & &1["run_id"]),
        error: queue["error"],
        forensic_report: forensic_report(queue["error"])
      })
    end
  end

  @spec reconciliation(
          Hancho.Project.t(),
          String.t(),
          String.t(),
          non_neg_integer(),
          map(),
          map(),
          keyword()
        ) :: :ok
  def reconciliation(project, queue_id, boundary, position, item, summary, options) do
    repository_state =
      if summary.clean,
        do: "clean",
        else: "changed (#{length(Map.get(summary, :changed_paths, []))} paths)"

    emit(
      project,
      queue_id,
      "queue.reconciled",
      "Reconciled #{boundary} item #{position + 1}: #{summary.branch} at #{summary.head}, #{repository_state}, #{length(summary.worktrees)} worktrees.",
      Map.merge(item_metadata(item, position, nil), %{boundary: boundary, state: summary}),
      false,
      options
    )
  end

  @spec emit(Hancho.Project.t(), String.t(), String.t(), String.t(), map(), boolean(), keyword()) ::
          :ok
  def emit(project, queue_id, event, message, metadata, important, options) do
    progress = Keyword.get(options, :progress, fn _message -> :ok end)
    _result = maybe_progress(progress, message, important, options)
    _result = write_audit(project, queue_id, event, message, metadata, options)
    :ok
  end

  @spec item_message(String.t(), map(), non_neg_integer(), non_neg_integer()) :: String.t()
  def item_message(action, item, position, total) do
    "[#{position + 1}/#{total}] #{action} #{item.issue_id}. Run: #{item.run_id}"
  end

  @spec item_metadata(map(), non_neg_integer(), non_neg_integer() | nil) :: map()
  def item_metadata(item, position, total) do
    %{issue_id: item.issue_id, run_id: item.run_id, position: position, total_count: total}
  end

  defp maybe_progress(progress, message, important, options) do
    if important or Keyword.get(options, :verbose, false) do
      try do
        case progress.(message) do
          :ok ->
            :ok

          other ->
            Hancho.Log.internal(:warning, "Queue progress callback failed",
              result: inspect(other)
            )
        end
      rescue
        error ->
          Hancho.Log.internal(:warning, "Queue progress callback failed", error: inspect(error))
      catch
        kind, reason ->
          Hancho.Log.internal(:warning, "Queue progress callback failed",
            error: inspect({kind, reason})
          )
      end
    else
      :ok
    end
  end

  defp write_audit(project, queue_id, event, message, metadata, options) do
    if Keyword.get(options, :log) == :disabled do
      :ok
    else
      with {:ok, log} <-
             Hancho.Audit.open(project, console: false, metadata: %{queue_id: queue_id}) do
        try do
          Hancho.Audit.write(log, message, event: event, metadata: metadata)
        after
          Hancho.Audit.close(log)
        end
      end
    end
  end

  defp forensic_report(error) when is_map(error) do
    Map.get(error, "forensic_report", Map.get(error, :forensic_report))
  end

  defp forensic_report(_error), do: nil
end
