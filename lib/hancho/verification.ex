defmodule Hancho.Verification do
  @moduledoc "Runs exact verification commands and stores their evidence."

  alias Hancho.Harness.ProcessRunner
  alias Hancho.{Artifacts, Clock, Error, Repository}

  @profiles %{
    "elixir_library" => [
      ["mix", "format", "--check-formatted"],
      ["mix", "compile", "--warnings-as-errors"],
      ["mix", "test"]
    ],
    "phoenix_private" => [
      ["mix", "format", "--check-formatted"],
      ["mix", "compile", "--warnings-as-errors"],
      ["mix", "test"]
    ]
  }

  @spec commands(String.t(), [[String.t()]]) :: [[String.t()]]
  def commands(profile, []), do: Map.get(@profiles, profile, @profiles["elixir_library"])
  def commands(_profile, configured), do: configured

  @spec run(Repository.t(), String.t(), Path.t(), [[String.t()]], keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run(repository, run_id, worktree, commands, options \\ []) do
    round = Keyword.get(options, :round, 1)

    results =
      commands
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {command, index}, acc ->
        case run_one(repository, run_id, worktree, command, round, index, options) do
          {:ok, result} -> {:cont, [result | acc]}
          {:error, result} -> {:halt, [result | acc]}
        end
      end)
      |> Enum.reverse()

    passed = length(results) == length(commands) and Enum.all?(results, &(&1.status == "passed"))
    {:ok, %{passed: passed, round: round, checks: results}}
  end

  defp run_one(
         repository,
         run_id,
         worktree,
         [command | args] = command_spec,
         round,
         index,
         options
       ) do
    run_dir = Artifacts.run_directory(repository, run_id)
    name = "round-#{round}-#{index}"
    stdout = Path.join([run_dir, "checks", "#{name}.stdout.log"])
    stderr = Path.join([run_dir, "checks", "#{name}.stderr.log"])
    started_at = Clock.utc_now()

    case ProcessRunner.run(command, args,
           cwd: worktree,
           stdout_path: stdout,
           stderr_path: stderr,
           timeout_ms: Keyword.get(options, :timeout_ms, 900_000),
           max_output_bytes: Keyword.get(options, :max_output_bytes, 10_485_760)
         ) do
      {:ok, process} ->
        finished_at = Clock.utc_now()

        result = %{
          name: name,
          command: command_spec,
          working_directory: worktree,
          status: if(process.status == "success", do: "passed", else: "failed"),
          process_status: process.status,
          exit_status: process.exit_status,
          started_at: started_at,
          finished_at: finished_at,
          stdout_path: stdout,
          stderr_path: stderr
        }

        Artifacts.write(
          repository,
          run_id,
          "check",
          "#{name}.stdout.log",
          File.read!(stdout),
          media_type: "text/plain",
          retention: "evidence"
        )

        Artifacts.write(
          repository,
          run_id,
          "check",
          "#{name}.stderr.log",
          File.read!(stderr),
          media_type: "text/plain",
          retention: "evidence"
        )

        Artifacts.write(repository, run_id, "check", "#{name}.json", Hancho.JSON.encode!(result),
          media_type: "application/json",
          retention: "evidence"
        )

        if result.status == "passed", do: {:ok, result}, else: {:error, result}

      {:error, error} ->
        {:error,
         %{
           name: name,
           command: command_spec,
           working_directory: worktree,
           status: "failed",
           error: Exception.message(error)
         }}
    end
  end
end
