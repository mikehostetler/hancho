defmodule Hancho.Workflow.Runner do
  @moduledoc "Runs one workflow in the foreground."

  alias Hancho.Workflow.{Loader, Runtime, Store}

  @spec run(Hancho.Project.t(), String.t(), map(), keyword()) ::
          {:ok, Hancho.Workflow.Result.t()} | {:error, term()}
  def run(project, workflow_name, input, options \\ []) do
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
