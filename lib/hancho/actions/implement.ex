defmodule Hancho.Actions.Implement do
  @moduledoc "Calls a CLI coding agent in the selected workspace."

  use Jido.Action,
    name: "hancho_implement",
    description: "Implements a Beadwork task with Jido.Harness",
    schema:
      Zoi.object(%{
        prompt: Zoi.string() |> Zoi.min(1),
        worktree_path: Zoi.string() |> Zoi.min(1),
        provider: Zoi.string() |> Zoi.min(1),
        reasoning_effort: Zoi.enum(["low", "medium", "high"]) |> Zoi.optional(),
        timeout_ms: Zoi.integer() |> Zoi.min(1),
        idle_timeout_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(300_000),
        progress_interval_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(30_000)
      })

  alias Hancho.Actions.Context
  alias Hancho.Harness.EventConsole

  @providers %{
    "amp" => :amp,
    "claude" => :claude,
    "codex" => :codex,
    "gemini" => :gemini,
    "grok" => :grok,
    "kimi" => :kimi,
    "opencode" => :opencode,
    "pi" => :pi,
    "zai" => :zai
  }

  @impl true
  def run(params, context) do
    harness = Context.service(context, :harness, Hancho.Harness)

    with {:ok, provider} <- fetch_provider(params.provider),
         {:ok, prior_run} <- prior_harness_run(context),
         {:ok, result} <- run_harness(harness, provider, params, prior_run, context),
         :ok <- completed(result) do
      {:ok,
       %{
         provider: params.provider,
         harness_run_id: result.run_id,
         status: result.status,
         text: tail(result.text, 20_000),
         text_truncated: result.text_truncated? or byte_size(result.text) > 20_000
       }}
    end
  end

  @spec provider(String.t()) :: {:ok, atom()} | {:error, String.t()}
  def provider(name), do: fetch_provider(name)

  defp run_harness(harness, provider, params, prior_run, context) do
    repository = repository_from_worktree(params.worktree_path)

    options =
      [
        cwd: params.worktree_path,
        approval_mode: approval_mode(provider),
        sandbox_mode: :workspace_write,
        reasoning_effort: params |> Map.get(:reasoning_effort) |> reasoning_effort(),
        runtime_timeout_ms: params.timeout_ms,
        idle_timeout_ms: min(params.idle_timeout_ms, params.timeout_ms),
        await_timeout: params.timeout_ms + 60_000,
        cancellation_timeout_ms: 30_000,
        progress_interval_ms: params.progress_interval_ms,
        journal_dir: Path.join([repository, ".hancho", "harness"]),
        resume_run_id: prior_run_id(prior_run),
        resume_cursor: prior_cursor(prior_run)
      ]
      |> verbose_event_options(context)

    if Code.ensure_loaded?(harness) and function_exported?(harness, :run_with_progress, 4) do
      harness.run_with_progress(provider, params.prompt, options, progress_callback(context))
    else
      harness.run(provider, params.prompt, Keyword.delete(options, :progress_interval_ms))
    end
  end

  # Grok's :auto_edit mode maps to acceptEdits, which can wait for interactive
  # approval of shell and web tools. Hancho runs Grok without an approval
  # responder, so use its non-interactive mode while the workspace sandbox
  # continues to limit filesystem access.
  defp approval_mode(:grok), do: :auto_approve
  defp approval_mode(_provider), do: :auto_edit

  defp reasoning_effort(nil), do: nil
  defp reasoning_effort("low"), do: :low
  defp reasoning_effort("medium"), do: :medium
  defp reasoning_effort("high"), do: :high

  defp progress_callback(context) do
    fn progress ->
      with :ok <- persist_harness_run(context, progress) do
        {label, event} = activity(context)

        _result =
          Hancho.Audit.write(context.log, "#{label} progress: #{progress.phase}",
            event: event,
            metadata: progress
          )

        :ok
      end
    end
  end

  defp prior_harness_run(context) do
    case Map.get(context, :effect_store) do
      %{api: api, store: store, run_id: run_id, step_position: position} ->
        if function_exported?(api, :fetch_step_operation, 4) do
          case api.fetch_step_operation(store, run_id, position, operation_kind(context)) do
            {:ok, nil} ->
              {:ok, nil}

            {:ok, %{"id" => harness_run_id} = operation} ->
              {:ok,
               %{
                 id: harness_run_id,
                 cursor: get_in(operation, ["metadata", "last_sequence"]) || 0
               }}

            {:error, reason} ->
              {:error, {:harness_operation_unavailable, reason}}
          end
        else
          {:ok, nil}
        end

      _other ->
        {:ok, nil}
    end
  end

  defp persist_harness_run(context, %{harness_run_id: harness_run_id} = progress)
       when is_binary(harness_run_id) do
    case Map.get(context, :effect_store) do
      %{api: api, store: store, run_id: run_id, step_position: position} ->
        if function_exported?(api, :record_step_operation, 6) do
          api.record_step_operation(
            store,
            run_id,
            position,
            operation_kind(context),
            harness_run_id,
            Map.drop(progress, [:harness_run_id])
          )
        else
          :ok
        end

      _other ->
        :ok
    end
  end

  defp persist_harness_run(_context, _progress), do: :ok

  defp verbose_event_options(options, %{verbose: true}) do
    Keyword.merge(options,
      event_callback: &EventConsole.write/1,
      event_poll_interval_ms: 500
    )
  end

  defp verbose_event_options(options, _context), do: options

  defp activity(%{activity: :repair}), do: {"Repair", "repair.progress"}
  defp activity(_context), do: {"Implementation", "implement.progress"}

  defp operation_kind(%{activity: :repair}), do: "jido_harness.repair"
  defp operation_kind(_context), do: "jido_harness.run"

  defp prior_run_id(%{id: id}), do: id
  defp prior_run_id(_prior_run), do: nil
  defp prior_cursor(%{cursor: cursor}) when is_integer(cursor) and cursor >= 0, do: cursor
  defp prior_cursor(_prior_run), do: 0

  defp repository_from_worktree(path) do
    parts = path |> Path.expand() |> Path.split()

    case Enum.find_index(parts, &(&1 == ".hancho")) do
      nil -> Path.expand(path)
      index -> parts |> Enum.take(index) |> Path.join()
    end
  end

  defp fetch_provider(name) do
    case Map.fetch(@providers, name) do
      {:ok, provider} -> {:ok, provider}
      :error -> {:error, "Unknown Jido.Harness provider: #{name}"}
    end
  end

  defp completed(%{status: :completed}), do: :ok
  defp completed(result), do: {:error, result.error || "The coding agent did not complete."}

  defp tail(text, limit) when byte_size(text) <= limit, do: text
  defp tail(text, limit), do: binary_part(text, byte_size(text) - limit, limit)
end
