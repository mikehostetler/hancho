defmodule Hancho.Harness.Grok do
  @moduledoc false
  @behaviour Hancho.Harness.Adapter

  alias Hancho.Harness.{ProcessRunner, Request, Result}
  alias Hancho.{Error, ID}

  @impl true
  def doctor(config) do
    command = config["command"] || "grok"

    if System.find_executable(command),
      do: {:ok, %{status: "pass", command: command}},
      else: {:error, missing(command)}
  end

  @impl true
  def version(config) do
    command = config["command"] || "grok"

    case System.cmd(command, ["--version"], stderr_to_stdout: true) do
      {output, 0} -> {:ok, %{adapter_version: "1", harness_version: String.trim(output)}}
      {_output, _status} -> {:error, missing(command)}
    end
  end

  @impl true
  def run(%Request{} = request, config) do
    command = config["command"] || "grok"
    session_id = ID.generate("grok")

    args = [
      "--output-format",
      "streaming-json",
      "--verbatim",
      "--no-memory",
      "--no-plan",
      "--permission-mode",
      config["permission_mode"] || "acceptEdits",
      "--deny",
      "Bash(git commit*)",
      "--deny",
      "Bash(git push*)",
      "--session-id",
      session_id,
      "--cwd",
      request.worktree_path,
      "--prompt-file",
      request.prompt_path
    ]

    args = if request.model, do: args ++ ["--model", request.model], else: args

    with {:ok, process} <-
           ProcessRunner.run(command, args,
             cwd: request.worktree_path,
             stdout_path: request.paths["stdout"],
             stderr_path: request.paths["stderr"],
             timeout_ms: request.limits["timeout_ms"] || 900_000,
             max_output_bytes: request.limits["max_output_bytes"] || 10_485_760
           ) do
      {:ok,
       %Result{
         status: process.status,
         adapter: "builtin:grok",
         harness: command,
         adapter_version: "1",
         harness_version: config["harness_version"],
         session_id: session_id,
         exit_status: process.exit_status,
         stdout_path: process.stdout_path,
         stderr_path: process.stderr_path
       }}
    end
  end

  defp missing(command),
    do: %Error{
      code: :harness_missing,
      exit_status: 69,
      message: "Harness command '#{command}' was not found."
    }
end
