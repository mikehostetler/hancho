defmodule Hancho.Harness.Executor do
  @moduledoc "Executes one routed harness station and records its durable identity and result."

  alias Hancho.Harness.{Request, Router}
  alias Hancho.Workflow.Definition

  alias Hancho.{
    Artifacts,
    Clock,
    Error,
    ID,
    InstructionPacks,
    Journal,
    JSON,
    Repository,
    SQLite,
    Store
  }

  @spec run_station(
          Repository.t(),
          map(),
          Definition.t(),
          map(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, Error.t() | term()}
  def run_station(repository, config, definition, work_order, station_id, prompt, options \\ []) do
    attempt = Keyword.get(options, :attempt, 1)

    with {:ok, resolved} <- Router.resolve(config, definition, station_id),
         guidance <-
           InstructionPacks.resolve(config, definition.name, station_id, %{
             design_work: Keyword.get(options, :design_work, false)
           }),
         :ok <- InstructionPacks.record(repository, work_order["id"], station_id, guidance),
         prompt <- guided_prompt(prompt, guidance),
         {:ok, prompt_artifact} <-
           Artifacts.write(
             repository,
             work_order["id"],
             "prompt",
             "#{station_id}-#{attempt}.md",
             prompt,
             media_type: "text/markdown",
             retention: "evidence"
           ),
         {:ok, action} <-
           Journal.request_action(
             repository,
             work_order["id"],
             station_id,
             "run_harness",
             "#{work_order["id"]}:#{station_id}:#{attempt}"
           ),
         {:ok, action} <- ensure_action_started(repository, action),
         {:ok, identity} <- resolved.module.version(adapter_config(resolved, repository, options)),
         {:ok, session} <- record_session(repository, config, resolved, work_order, identity),
         {:ok, _guidance_event} <-
           Journal.record_event(repository, work_order["id"], "guidance_resolved",
             actor: "hancho",
             reason: "Instruction guidance was resolved before station start",
             payload: %{
               station: station_id,
               packs:
                 Enum.map(guidance, fn item ->
                   Map.take(item, [:name, :version, :source, :hash, :status, :reason])
                 end)
             }
           ),
         {:ok, _started_event} <-
           Journal.record_event(repository, work_order["id"], "harness_started",
             actor: "hancho",
             reason: "Resolved harness started",
             payload: %{
               station: station_id,
               harness: resolved.name,
               adapter: resolved.config["adapter"],
               capability: resolved.station.capability,
               authority: resolved.station.authority
             }
           ),
         request <-
           request(
             repository,
             config,
             definition,
             work_order,
             resolved,
             prompt_artifact,
             attempt,
             options
           ),
         result <-
           safe_run(resolved.module, request, adapter_config(resolved, repository, options)),
         {:ok, outcome} <- finish(repository, config, action, session, result) do
      {:ok, Map.merge(outcome, %{resolved: resolved, prompt_artifact: prompt_artifact})}
    end
  end

  defp guided_prompt(prompt, guidance) do
    case InstructionPacks.prompt_fragment(guidance) do
      "" -> prompt
      fragment -> prompt <> "\n\nResolved guidance:\n\n" <> fragment
    end
  end

  defp ensure_action_started(repository, %{"status" => "requested"} = action),
    do: Journal.start_action(repository, action["id"])

  defp ensure_action_started(_repository, %{"status" => "started"} = action), do: {:ok, action}

  defp ensure_action_started(_repository, action) do
    {:error,
     %Error{
       code: :action_not_runnable,
       exit_status: 75,
       message: "Action '#{action["id"]}' is already '#{action["status"]}'."
     }}
  end

  defp request(
         repository,
         config,
         definition,
         work_order,
         resolved,
         prompt_artifact,
         attempt,
         options
       ) do
    run_dir = Artifacts.run_directory(repository, work_order["id"])
    prefix = "#{resolved.station.id}-#{attempt}"

    %Request{
      run_id: work_order["id"],
      workflow: definition.name,
      workflow_version: definition.version,
      station: resolved.station.id,
      repository_path: repository.root,
      worktree_path: Keyword.get(options, :worktree_path, repository.root),
      prompt_path: Path.join(repository.runtime_dir, prompt_artifact["relative_path"]),
      capability: resolved.station.capability,
      authority: resolved.station.authority,
      model: Keyword.get(options, :model),
      paths: %{
        "request" => Path.join([run_dir, "artifacts", "#{prefix}-request.json"]),
        "stdout" => Path.join([run_dir, "logs", "#{prefix}.stdout.log"]),
        "stderr" => Path.join([run_dir, "logs", "#{prefix}.stderr.log"])
      },
      limits: %{
        "timeout_ms" => get_in(config.data, ["limits", "harness_timeout_ms"]) || 900_000,
        "max_output_bytes" => get_in(config.data, ["limits", "max_output_bytes"]) || 10_485_760
      }
    }
  end

  defp safe_run(module, request, adapter_config) do
    module.run(request, adapter_config)
  rescue
    error ->
      {:error,
       %Error{
         code: :adapter_crashed,
         exit_status: 75,
         message: "Harness adapter crashed: #{Exception.message(error)}"
       }}
  catch
    kind, value ->
      {:error,
       %Error{
         code: :adapter_crashed,
         exit_status: 75,
         message: "Harness adapter stopped: #{inspect({kind, value})}"
       }}
  end

  defp finish(repository, config, action, session, {:ok, result}) do
    ensure_log_files(result)
    action_status = if result.status == "success", do: "completed", else: "failed"

    with {:ok, _action} <-
           Journal.finish_action(repository, action["id"], action_status, Map.from_struct(result)),
         :ok <- finish_session(repository, session["id"], result.status),
         {:ok, _event} <-
           Journal.record_event(repository, action["run_id"], "harness_completed",
             actor: "harness",
             reason: "Harness session ended with #{result.status}",
             payload: %{
               station: session["station"],
               session_id: session["id"],
               status: result.status
             }
           ),
         {:ok, stdout} <-
           index_existing_log(
             repository,
             config,
             action["run_id"],
             result.stdout_path,
             "stdout"
           ),
         {:ok, stderr} <-
           index_existing_log(
             repository,
             config,
             action["run_id"],
             result.stderr_path,
             "stderr"
           ) do
      {:ok,
       %{
         result: result,
         action: action,
         session: session,
         stdout_artifact: stdout,
         stderr_artifact: stderr
       }}
    end
  end

  defp finish(repository, _config, action, session, {:error, error}) do
    Journal.finish_action(repository, action["id"], "failed", %{error: Exception.message(error)})
    finish_session(repository, session["id"], "failure")

    Journal.record_event(repository, action["run_id"], "harness_failed",
      actor: "hancho",
      reason: Exception.message(error),
      payload: %{station: session["station"], session_id: session["id"]}
    )

    {:error, error}
  end

  defp record_session(repository, config, resolved, work_order, identity) do
    id = ID.generate("session")
    now = Clock.utc_now()

    sql = """
    INSERT INTO harness_sessions
      (id, run_id, station, adapter, harness, adapter_version, harness_version, capabilities_json,
       config_hash, status, started_at)
    VALUES
      (#{q(id)}, #{q(work_order["id"])}, #{q(resolved.station.id)}, #{q(resolved.config["adapter"])},
       #{q(resolved.config["command"])}, #{q(identity[:adapter_version])}, #{q(identity[:harness_version])},
       #{q(JSON.encode!(resolved.config["capabilities"] || []))}, #{q(config.hash)}, 'started', #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, [session]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM harness_sessions WHERE id = #{q(id)};"
           ) do
      {:ok, session}
    end
  end

  defp finish_session(repository, session_id, status) do
    SQLite.execute(
      Store.path(repository),
      "UPDATE harness_sessions SET status = #{q(status)}, finished_at = #{q(Clock.utc_now())} WHERE id = #{q(session_id)};"
    )
  end

  defp ensure_log_files(result) do
    for path <- [result.stdout_path, result.stderr_path],
        is_binary(path),
        not File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "")
    end
  end

  defp index_existing_log(repository, config, run_id, path, stream) do
    content = if is_binary(path) and File.exists?(path), do: File.read!(path), else: ""
    content = Hancho.Redactor.redact(content, config)
    name = Path.basename(path || "#{stream}.log")

    Artifacts.write(repository, run_id, "log", name, content,
      media_type: "text/plain",
      retention: "sensitive_raw"
    )
  end

  defp adapter_config(resolved, repository, options) do
    resolved.config
    |> Map.put("repository_path", repository.root)
    |> Map.put("cancel_ref", Keyword.get(options, :cancel_ref))
  end

  defp q(value), do: SQLite.quote(value)
end
