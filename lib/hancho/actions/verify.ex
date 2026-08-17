defmodule Hancho.Actions.Verify do
  @moduledoc "Runs the configured verification command."

  use Jido.Action,
    name: "hancho_verify",
    description: "Runs a verification command in the worktree",
    schema:
      Zoi.object(%{
        worktree_path: Zoi.string() |> Zoi.min(1),
        executable: Zoi.string() |> Zoi.min(1),
        arguments: Zoi.array(Zoi.string()),
        timeout_ms: Zoi.integer() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context
  alias Hancho.Command.Result

  @impl true
  def run(params, context) do
    command = Context.service(context, :command, Hancho.Command)
    executable = System.find_executable(params.executable) || params.executable
    sink = Hancho.Log.output_sink(context.log, event_prefix: "verify")

    case command.run(executable, params.arguments,
           cwd: params.worktree_path,
           timeout: params.timeout_ms,
           stderr_to_stdout: true,
           on_output: sink
         ) do
      {:ok, %Result{exit_status: 0, stdout: output}} ->
        {:ok, %{exit_status: 0, output: tail(output, 20_000)}}

      {:ok, %Result{exit_status: status, stdout: output}} ->
        {:error, "Verification failed with exit status #{status}:\n#{tail(output, 20_000)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp tail(text, limit) when byte_size(text) <= limit, do: text
  defp tail(text, limit), do: binary_part(text, byte_size(text) - limit, limit)
end
