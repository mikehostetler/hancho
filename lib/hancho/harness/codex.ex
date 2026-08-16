defmodule Hancho.Harness.Codex do
  @moduledoc "Runs the Codex CLI as a bounded Hancho harness adapter."
  @behaviour Hancho.Harness.Adapter

  alias Hancho.Harness.{ProcessRunner, Request, Result}
  alias Hancho.{Error, ID}

  @impl true
  def doctor(config) do
    case executable(config) do
      nil -> {:error, error(:codex_unavailable, "The configured Codex CLI was not found.")}
      path -> {:ok, %{status: "pass", adapter: "builtin:codex", executable: path}}
    end
  end

  @impl true
  def version(config) do
    case executable(config) do
      nil ->
        {:error, error(:codex_unavailable, "The configured Codex CLI was not found.")}

      path ->
        case System.cmd(path, ["--version"], stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, %{adapter_version: "1", harness_version: String.trim(output)}}

          {output, status} ->
            {:error,
             error(
               :codex_version_failed,
               "Codex version failed with #{status}: #{String.trim(output)}"
             )}
        end
    end
  end

  @impl true
  def run(%Request{} = request, config) do
    with path when is_binary(path) <- executable(config),
         {:ok, process} <-
           ProcessRunner.run(path, arguments(request),
             cwd: request.worktree_path,
             stdout_path: request.paths["stdout"],
             stderr_path: request.paths["stderr"],
             timeout_ms: request.limits["timeout_ms"] || 900_000,
             max_output_bytes: request.limits["max_output_bytes"] || 10_485_760,
             cancel_ref: config["cancel_ref"]
           ) do
      {:ok,
       %Result{
         status: process.status,
         adapter: "builtin:codex",
         harness: config["command"] || "codex",
         adapter_version: "1",
         harness_version: version_text(config),
         session_id: ID.generate("codex"),
         exit_status: process.exit_status,
         stdout_path: process.stdout_path,
         stderr_path: process.stderr_path,
         events: [%{"type" => "event", "name" => "codex.completed", "status" => process.status}]
       }}
    else
      nil -> {:error, error(:codex_unavailable, "The configured Codex CLI was not found.")}
      {:error, failure} -> {:error, failure}
    end
  end

  defp arguments(request) do
    sandbox = if request.capability == "edit_worktree", do: "workspace-write", else: "read-only"

    ["exec", "--skip-git-repo-check", "--sandbox", sandbox, "-C", request.worktree_path] ++
      model_argument(request.model) ++ [File.read!(request.prompt_path)]
  end

  defp model_argument(nil), do: []
  defp model_argument(model), do: ["--model", model]

  defp executable(config) do
    command = config["command"] || System.get_env("HANCHO_CODEX") || "codex"

    cond do
      Path.type(command) == :absolute and File.exists?(command) ->
        command

      String.contains?(command, "/") ->
        Path.expand(command, config["repository_path"] || File.cwd!())

      true ->
        System.find_executable(command)
    end
  end

  defp version_text(config) do
    case version(config) do
      {:ok, identity} -> identity.harness_version
      _ -> nil
    end
  end

  defp error(code, message), do: %Error{code: code, exit_status: 69, message: message}
end
