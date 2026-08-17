defmodule Hancho.Workflow.Runner do
  @moduledoc "Runs one workflow in the foreground."

  alias Hancho.Workflow.{Definition, Loader, RunReconciler, Runtime, Store}

  @spec run(Hancho.Project.t(), String.t(), map(), keyword()) ::
          {:ok, Hancho.Workflow.Result.t()} | {:error, term()}
  def run(project, workflow_name, input, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "run #{workflow_name}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_run(project, workflow_name, input, options)
    end)
  end

  defp do_run(project, workflow_name, input, options) do
    loader = Keyword.get(options, :loader, Loader)
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, definition, workflow_source} <- loader.load_with_source(project, workflow_name),
         {:ok, store} <- store_api.open(project.bedrock_path) do
      result = run_with_store(project, definition, workflow_source, input, store, options)

      case close_store(store_api, store, options) do
        :ok -> result
        {:error, reason} -> {:error, {:state_flush_failed, reason}}
      end
    end
  end

  @spec retry(Hancho.Project.t(), String.t(), keyword()) ::
          {:ok, Hancho.Workflow.Result.t()} | {:error, term()}
  def retry(project, run_id, options \\ []) do
    lease_options = Keyword.put_new(options, :lease_command, "retry #{run_id}")

    Hancho.FactoryLease.with_lease(project, lease_options, fn ->
      do_retry(project, run_id, options)
    end)
  end

  defp do_retry(project, run_id, options) do
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, store} <- store_api.open(project.bedrock_path) do
      result = retry_with_store(project, run_id, store, options)

      case close_store(store_api, store, options) do
        :ok -> result
        {:error, reason} -> {:error, {:state_flush_failed, reason}}
      end
    end
  end

  defp run_with_store(project, definition, workflow_source, input, store, options) do
    run_id = Keyword.get_lazy(options, :run_id, &new_run_id/0)
    store_api = Keyword.get(options, :store_api, Store)

    with {:ok, log} <- open_log(project, run_id, options) do
      try do
        with :ok <- store_api.create_run(store, run_id, definition, input, workflow_source),
             :ok <- log_workflow_source(log, definition, workflow_source),
             {:ok, pid} <-
               Runtime.start_link(%{
                 definition: definition,
                 input: Hancho.Log.Event.normalize(input),
                 run_id: run_id,
                 store: store,
                 store_api: store_api,
                 registry: Keyword.get(options, :registry, Hancho.Workflow.Registry),
                 executor: Keyword.get(options, :executor, Hancho.Workflow.Executor),
                 services: Keyword.get(options, :services, %{}),
                 log: log
               }) do
          {:ok, Runtime.run(pid)}
        end
      after
        Hancho.Log.close(log)
      end
    end
  end

  defp retry_with_store(project, run_id, store, options) do
    store_api = Keyword.get(options, :store_api, Store)
    reconciler = Keyword.get(options, :reconciler, RunReconciler)

    with {:ok, run} <- store_api.fetch_run(store, run_id),
         :ok <- resumable_run(run),
         {:ok, definition} <- definition_from_snapshot(run),
         {:ok, input} <- Jason.decode(run["input_json"]),
         {:ok, steps} <- store_api.list_steps(store, run_id),
         {:ok, position} <- resumable_position(steps),
         {:ok, outputs} <- completed_outputs(steps),
         {:ok, _summary} <- reconciler.retry(project, outputs, reconcile_options(options)),
         {:ok, log} <- open_log(project, run_id, options) do
      try do
        with :ok <- store_api.retry_run(store, run_id, position),
             :ok <-
               Hancho.Log.write(log, "Workflow retry started",
                 event: "workflow.retry_started",
                 metadata: %{step: Enum.at(definition.steps, position).name}
               ),
             {:ok, pid} <-
               Runtime.start_link(%{
                 definition: definition,
                 input: Hancho.Log.Event.normalize(input),
                 run_id: run_id,
                 store: store,
                 store_api: store_api,
                 registry: Keyword.get(options, :registry, Hancho.Workflow.Registry),
                 executor: Keyword.get(options, :executor, Hancho.Workflow.Executor),
                 services: Keyword.get(options, :services, %{}),
                 log: log,
                 index: position,
                 outputs: outputs
               }) do
          {:ok, Runtime.run(pid)}
        end
      after
        Hancho.Log.close(log)
      end
    end
  end

  defp open_log(project, run_id, options) do
    case Keyword.get(options, :log) do
      :disabled ->
        {:ok, :disabled}

      _other ->
        with {:ok, config} <- Hancho.Config.load(project) do
          Hancho.Log.open(project, config, metadata: %{run_id: run_id})
        end
    end
  end

  defp close_store(store_api, store, options) do
    if Keyword.get(options, :flush_state, true) do
      store_api.close(store)
    else
      :ok
    end
  end

  defp resumable_run(%{"status" => status})
       when status in ["stopped", "running", "recovery_required"],
       do: :ok

  defp resumable_run(%{"status" => status}), do: {:error, {:run_not_resumable, status}}

  defp definition_from_snapshot(run) do
    yaml = run["workflow_yaml"]

    with true <- sha256(yaml) == run["workflow_sha256"] || {:error, :workflow_snapshot_changed},
         {:ok, values} <- YamlElixir.read_from_string(yaml),
         {:ok, definition} <- Definition.new(values) do
      {:ok, definition}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp resumable_position(steps) do
    case Enum.find(steps, &(&1["status"] in ["stopped", "running", "recovery_required"])) do
      nil -> {:error, :resumable_step_not_found}
      step -> {:ok, step["position"]}
    end
  end

  defp completed_outputs(steps) do
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, outputs} ->
      if step["status"] == "completed" do
        case Jason.decode(step["result_json"]) do
          {:ok, result} -> {:cont, {:ok, Map.put(outputs, step["name"], result)}}
          {:error, reason} -> {:halt, {:error, {:invalid_step_result, reason}}}
        end
      else
        {:cont, {:ok, outputs}}
      end
    end)
  end

  defp reconcile_options(options), do: Keyword.take(options, [:git])

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)

  defp log_workflow_source(log, definition, source) do
    Hancho.Log.write(log, "Workflow snapshot",
      event: "workflow.snapshot",
      metadata: %{
        workflow: definition.name,
        version: definition.version,
        path: source.path,
        yaml: source.yaml,
        sha256: source.sha256
      }
    )
  end

  defp new_run_id do
    suffix = :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
    "#{System.system_time(:millisecond)}-#{suffix}"
  end
end
