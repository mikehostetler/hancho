defmodule Hancho.Actions.Implement do
  @moduledoc "Calls a CLI coding agent in the isolated worktree."

  use Jido.Action,
    name: "hancho_implement",
    description: "Implements a Beadwork task with Jido.Harness",
    schema:
      Zoi.object(%{
        prompt: Zoi.string() |> Zoi.min(1),
        worktree_path: Zoi.string() |> Zoi.min(1),
        provider: Zoi.string() |> Zoi.min(1),
        timeout_ms: Zoi.integer() |> Zoi.min(1),
        progress_interval_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(30_000)
      })

  alias Hancho.Actions.Context

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
         {:ok, result} <- run_harness(harness, provider, params, context),
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

  defp run_harness(harness, provider, params, context) do
    options = [
      cwd: params.worktree_path,
      approval_mode: :auto_edit,
      sandbox_mode: :workspace_write,
      runtime_timeout_ms: params.timeout_ms,
      await_timeout: params.timeout_ms,
      progress_interval_ms: params.progress_interval_ms
    ]

    if Code.ensure_loaded?(harness) and function_exported?(harness, :run_with_progress, 4) do
      harness.run_with_progress(provider, params.prompt, options, progress_callback(context))
    else
      harness.run(provider, params.prompt, Keyword.delete(options, :progress_interval_ms))
    end
  end

  defp progress_callback(context) do
    fn progress ->
      Hancho.Log.write(context.log, "Implementation progress: #{progress.phase}",
        event: "implement.progress",
        metadata: progress
      )
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
