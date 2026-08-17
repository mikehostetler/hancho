defmodule Hancho.Workflow.QueueRunner do
  @moduledoc "Runs a durable workflow queue serially in the foreground."

  alias Hancho.Workflow.{Compiler, Loader, QueueReconciler, QueueResult, Runner, Store}

  @source "beadwork-ready"

  @spec run(Hancho.Project.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, QueueResult.t()} | {:error, term()}
  def run(project, workflow, source, count, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "queue #{workflow}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_run(project, workflow, source, count, options)
    end)
  end

  defp do_run(project, workflow, source, count, options) do
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)

    with :ok <- validate_request(source, count),
         {:ok, issues} <- ready_issues(beadwork, project.root, count),
         queue_id = Keyword.get_lazy(options, :queue_id, &new_queue_id/0),
         items = queue_items(queue_id, issues),
         {:ok, repository_state} <- reconciler.initial(project, reconcile_options(options)),
         {:ok, store} <- store_api.open(project.bedrock_path) do
      result =
        run_with_store(
          project,
          workflow,
          source,
          items,
          queue_id,
          repository_state,
          store,
          options
        )

      case store_api.close(store) do
        :ok -> result
        {:error, reason} -> {:error, {:state_flush_failed, reason}}
      end
    end
  end

  @spec resume(Hancho.Project.t(), String.t(), keyword()) ::
          {:ok, QueueResult.t()} | {:error, term()}
  def resume(project, queue_id, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "resume #{queue_id}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_resume(project, queue_id, options)
    end)
  end

  defp do_resume(project, queue_id, options) do
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, store} <- store_api.open(project.bedrock_path) do
      result = resume_with_store(project, queue_id, store, options)

      case store_api.close(store) do
        :ok -> result
        {:error, reason} -> {:error, {:state_flush_failed, reason}}
      end
    end
  end

  @spec preview(Hancho.Project.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def preview(project, workflow, source, count, options \\ []) do
    beadwork = Keyword.get(options, :beadwork, Hancho.Beadwork)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)
    loader = Keyword.get(options, :loader, Loader)
    compiler = Keyword.get(options, :compiler, Compiler)

    with :ok <- validate_request(source, count),
         {:ok, issues} <- ready_issues(beadwork, project.root, count),
         {:ok, repository} <- reconciler.initial(project, reconcile_options(options)),
         {:ok, definition} <- loader.load(project, workflow),
         {:ok, compilation} <-
           compiler.compile(
             project,
             definition,
             %{"repo_path" => project.root, "issue_id" => hd(issues)["id"]},
             options
           ) do
      {:ok,
       %{
         workflow: workflow,
         source: source,
         issues: Enum.map(issues, &Map.take(&1, ["id", "title", "status"])),
         repository: %{
           branch: repository.branch,
           head: repository.head,
           clean: true,
           worktrees: repository.worktrees
         },
         settings: workflow_settings(definition),
         compilation: compilation
       }}
    end
  end

  defp workflow_settings(definition) do
    implement = Enum.find(definition.steps, &(&1.action == "Hancho.Actions.Implement"))
    verify = Enum.find(definition.steps, &(&1.action == "Hancho.Actions.Verify"))

    %{
      provider: step_param(implement, "provider"),
      implementation_timeout_ms: step_param(implement, "timeout_ms"),
      verification_timeout_ms: step_param(verify, "timeout_ms")
    }
  end

  defp step_param(nil, _name), do: nil
  defp step_param(step, name), do: Map.get(step.params, name)

  defp run_with_store(
         project,
         workflow,
         source,
         items,
         queue_id,
         repository_state,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)

    with :ok <-
           store_api.create_queue(
             store,
             queue_id,
             workflow,
             source,
             items,
             repository_state
           ),
         :ok <- store_api.close(store),
         :ok <-
           emit(
             project,
             queue_id,
             "queue.started",
             "Queue #{queue_id} selected #{length(items)} tasks.",
             %{workflow: workflow, source: source, issues: Enum.map(items, & &1.issue_id)},
             true,
             options
           ) do
      run_items(project, workflow, queue_id, items, 0, store, options)
    end
  end

  defp resume_with_store(project, queue_id, store, options) do
    store_api = Keyword.get(options, :store_api, Store)
    runner = Keyword.get(options, :workflow_runner, Runner)

    with {:ok, queue} <- store_api.fetch_queue(store, queue_id),
         :ok <- resumable_queue(queue),
         items = queue_items_from_state(queue),
         position = queue["current_position"],
         item = Enum.at(items, position),
         {:ok, recovery} <- child_recovery(store_api, store, item.run_id),
         :ok <- store_api.resume_queue(store, queue_id),
         :ok <- store_api.close(store),
         :ok <-
           emit(
             project,
             queue_id,
             "queue.resumed",
             "Queue #{queue_id} resumed at #{item.issue_id}.",
             item_metadata(item, position, length(items)),
             true,
             options
           ),
         :ok <-
           emit(
             project,
             queue_id,
             recovery_event(recovery),
             item_message(recovery_verb(recovery), item, position, length(items)),
             item_metadata(item, position, length(items)) |> Map.put(:recovery, recovery),
             true,
             options
           ) do
      child_options =
        options
        |> Keyword.put(:run_id, item.run_id)
        |> Keyword.put(:factory_lease, :held)

      case recover_child(runner, recovery, project, queue["workflow_name"], item, child_options) do
        {:ok, %{status: :completed} = result} ->
          complete_item(
            project,
            queue["workflow_name"],
            queue_id,
            items,
            position,
            item,
            result,
            store,
            options
          )

        {:ok, %{status: :stopped} = result} ->
          stop_item(
            project,
            queue["workflow_name"],
            queue_id,
            items,
            position,
            item,
            result,
            store,
            options
          )

        {:error, reason} ->
          stop_for_error(
            project,
            queue["workflow_name"],
            queue_id,
            items,
            position,
            item,
            %{
              code: "child_recovery_failed",
              recovery: recovery,
              error: Hancho.Log.Event.normalize(reason)
            },
            store,
            options
          )
      end
    end
  end

  defp run_items(project, workflow, queue_id, items, position, store, options)
       when position == length(items) do
    store_api = Keyword.get(options, :store_api, Store)

    with :ok <- store_api.complete_queue(store, queue_id),
         :ok <- store_api.close(store),
         :ok <-
           emit(
             project,
             queue_id,
             "queue.completed",
             "Queue #{queue_id} completed #{length(items)}/#{length(items)} tasks.",
             %{completed_count: length(items), total_count: length(items)},
             true,
             options
           ) do
      queue_result(store_api, store, queue_id, workflow)
    end
  end

  defp run_items(project, workflow, queue_id, items, position, store, options) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)
    runner = Keyword.get(options, :workflow_runner, Runner)
    item = Enum.at(items, position)

    with {:ok, queue} <- store_api.fetch_queue(store, queue_id),
         {:ok, summary} <- reconciler.before_item(project, queue, reconcile_options(options)),
         :ok <-
           emit_reconciliation(
             project,
             queue_id,
             "before",
             position,
             item,
             summary,
             options
           ),
         :ok <- store_api.start_queue_item(store, queue_id, position),
         :ok <- store_api.close(store),
         :ok <-
           emit(
             project,
             queue_id,
             "queue.item_started",
             item_message("Starting", item, position, length(items)),
             item_metadata(item, position, length(items)),
             true,
             options
           ) do
      child_options =
        options
        |> Keyword.put(:run_id, item.run_id)
        |> Keyword.put(:factory_lease, :held)

      case runner.run(
             project,
             workflow,
             %{"repo_path" => project.root, "issue_id" => item.issue_id},
             child_options
           ) do
        {:ok, %{status: :completed} = result} ->
          complete_item(
            project,
            workflow,
            queue_id,
            items,
            position,
            item,
            result,
            store,
            options
          )

        {:ok, %{status: :stopped} = result} ->
          stop_item(project, workflow, queue_id, items, position, item, result, store, options)

        {:error, reason} ->
          stop_for_error(
            project,
            workflow,
            queue_id,
            items,
            position,
            item,
            %{code: "child_run_failed", error: Hancho.Log.Event.normalize(reason)},
            store,
            options
          )
      end
    else
      {:error, reason} ->
        stop_for_error(
          project,
          workflow,
          queue_id,
          items,
          position,
          item,
          reason,
          store,
          options
        )
    end
  end

  defp complete_item(
         project,
         workflow,
         queue_id,
         items,
         position,
         item,
         result,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)

    with {:ok, queue} <- store_api.fetch_queue(store, queue_id),
         {:ok, summary} <-
           reconciler.after_run(project, queue, result.outputs, reconcile_options(options)),
         :ok <-
           emit_reconciliation(
             project,
             queue_id,
             "after",
             position,
             item,
             summary,
             options
           ),
         landed when is_binary(landed) <- get_in(result.outputs, ["land", "commit"]),
         :ok <- store_api.complete_queue_item(store, queue_id, position, landed),
         :ok <- store_api.close(store),
         :ok <-
           emit(
             project,
             queue_id,
             "queue.item_completed",
             item_message("Completed", item, position, length(items)),
             item_metadata(item, position, length(items)) |> Map.put(:head, landed),
             true,
             options
           ) do
      run_items(project, workflow, queue_id, items, position + 1, store, options)
    else
      nil ->
        stop_for_error(
          project,
          workflow,
          queue_id,
          items,
          position,
          item,
          %{code: "missing_landed_commit"},
          store,
          options
        )

      {:error, reason} ->
        stop_for_error(
          project,
          workflow,
          queue_id,
          items,
          position,
          item,
          reason,
          store,
          options
        )
    end
  end

  defp stop_item(
         project,
         workflow,
         queue_id,
         items,
         position,
         item,
         result,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, QueueReconciler)

    with {:ok, queue} <- store_api.fetch_queue(store, queue_id),
         {:ok, summary} <-
           reconciler.after_run(project, queue, result.outputs, reconcile_options(options)),
         :ok <-
           emit_reconciliation(
             project,
             queue_id,
             "after",
             position,
             item,
             summary,
             options
           ) do
      stop_for_error(
        project,
        workflow,
        queue_id,
        items,
        position,
        item,
        %{code: "workflow_stopped", step: result.current_step, error: result.error},
        store,
        options
      )
    else
      {:error, reason} ->
        stop_for_error(
          project,
          workflow,
          queue_id,
          items,
          position,
          item,
          reason,
          store,
          options
        )
    end
  end

  defp stop_for_error(
         project,
         workflow,
         queue_id,
         items,
         position,
         item,
         error,
         store,
         options
       ) do
    store_api = Keyword.get(options, :store_api, Store)
    event = if out_of_sync?(error), do: "queue.reconciliation_failed", else: "queue.stopped"
    message = item_message("Stopped", item, position, length(items)) <> ": #{inspect(error)}"

    with :ok <- store_api.stop_queue_item(store, queue_id, position, error),
         :ok <- store_api.close(store),
         :ok <-
           emit(
             project,
             queue_id,
             event,
             message,
             Map.put(item_metadata(item, position, length(items)), :error, error),
             true,
             options
           ) do
      queue_result(store_api, store, queue_id, workflow)
    end
  end

  defp queue_result(store_api, store, queue_id, workflow) do
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
        error: queue["error"]
      })
    end
  end

  defp select_issues(ready, count) do
    selected =
      ready
      |> Enum.filter(&ready_task?/1)
      |> Enum.take(count)

    if length(selected) == count do
      {:ok, selected}
    else
      {:error, "Beadwork has #{length(selected)} ready tasks; #{count} are required."}
    end
  end

  defp ready_issues(beadwork, repository, count) do
    with {:ok, ready} <- beadwork.ready(working_dir: repository),
         {:ok, candidates} <- task_candidates(beadwork, repository, ready, count) do
      select_issues(candidates, count)
    end
  end

  defp task_candidates(beadwork, repository, ready, count) do
    tasks = Enum.filter(ready, &ready_task?/1)

    if length(tasks) >= count,
      do: {:ok, tasks},
      else: ready_tasks_from_all(beadwork, repository)
  end

  defp ready_tasks_from_all(beadwork, repository) do
    with {:ok, issues} <- beadwork.list_all(working_dir: repository) do
      statuses = Map.new(issues, &{&1["id"], &1["status"]})

      ready =
        issues
        |> Enum.filter(&ready_task_from_all?(&1, statuses))
        |> Enum.sort_by(&queue_order/1)

      {:ok, ready}
    end
  end

  defp ready_task_from_all?(issue, statuses) do
    ready_task?(issue) and
      Enum.all?(issue["blocked_by"] || [], &(Map.get(statuses, &1) == "closed"))
  end

  defp queue_order(issue) do
    ordinal =
      case Regex.run(~r/Queue ordinal: `(\d+)`/, issue["description"] || "") do
        [_, value] -> String.to_integer(value)
        nil -> 2_147_483_647
      end

    {ordinal, issue["id"]}
  end

  defp ready_task?(issue) do
    issue["type"] == "task" and issue["status"] in ["open", "in_progress"] and
      is_binary(issue["id"])
  end

  defp queue_items(queue_id, issues) do
    issues
    |> Enum.with_index()
    |> Enum.map(fn {issue, position} ->
      %{
        position: position,
        issue_id: issue["id"],
        run_id:
          "#{queue_id}-#{(position + 1) |> Integer.to_string() |> String.pad_leading(3, "0")}"
      }
    end)
  end

  defp queue_items_from_state(queue) do
    Enum.map(queue["items"], fn item ->
      %{
        position: item["position"],
        issue_id: item["issue_id"],
        run_id: item["run_id"]
      }
    end)
  end

  defp resumable_queue(%{"status" => status, "items" => items, "current_position" => position})
       when status in ["stopped", "running", "recovery_required"] do
    case Enum.at(items, position) do
      %{"status" => item_status} when item_status in ["pending", "stopped", "running"] -> :ok
      _item -> {:error, :resumable_queue_item_not_found}
    end
  end

  defp resumable_queue(%{"status" => status}), do: {:error, {:queue_not_resumable, status}}

  defp child_recovery(store_api, store, run_id) do
    if function_exported?(store_api, :fetch_run, 2) do
      case store_api.fetch_run(store, run_id) do
        {:ok, _run} -> {:ok, :retry}
        {:error, :not_found} -> {:ok, :start}
        {:error, reason} -> {:error, {:child_state_unavailable, reason}}
      end
    else
      {:ok, :retry}
    end
  end

  defp recover_child(runner, :retry, project, _workflow, item, options) do
    runner.retry(project, item.run_id, options)
  end

  defp recover_child(runner, :start, project, workflow, item, options) do
    runner.run(
      project,
      workflow,
      %{"repo_path" => project.root, "issue_id" => item.issue_id},
      options
    )
  end

  defp recovery_event(:retry), do: "queue.item_retried"
  defp recovery_event(:start), do: "queue.item_restarted"
  defp recovery_verb(:retry), do: "Retrying"
  defp recovery_verb(:start), do: "Restarting"

  defp validate_request(@source, count) when is_integer(count) and count > 0, do: :ok

  defp validate_request(source, _count) when source != @source,
    do: {:error, "Unknown queue source: #{source}"}

  defp validate_request(_source, _count), do: {:error, "Queue count must be a positive integer."}

  defp emit_reconciliation(project, queue_id, boundary, position, item, summary, options) do
    emit(
      project,
      queue_id,
      "queue.reconciled",
      "Reconciled #{boundary} item #{position + 1}: #{summary.branch} at #{summary.head}, clean, #{length(summary.worktrees)} worktrees.",
      Map.merge(item_metadata(item, position, nil), %{boundary: boundary, state: summary}),
      false,
      options
    )
  end

  defp emit(project, queue_id, event, message, metadata, important, options) do
    progress = Keyword.get(options, :progress, fn _message -> :ok end)
    _result = maybe_progress(progress, message, important, options)
    _result = write_audit(project, queue_id, event, message, metadata, options)
    :ok
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

  defp item_message(action, item, position, total) do
    "[#{position + 1}/#{total}] #{action} #{item.issue_id}. Run: #{item.run_id}"
  end

  defp item_metadata(item, position, total) do
    %{issue_id: item.issue_id, run_id: item.run_id, position: position, total_count: total}
  end

  defp reconcile_options(options), do: Keyword.take(options, [:git])

  defp out_of_sync?(%{code: "filesystem_out_of_sync"}), do: true
  defp out_of_sync?(_error), do: false

  defp new_queue_id do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "queue-#{System.system_time(:millisecond)}-#{suffix}"
  end
end
