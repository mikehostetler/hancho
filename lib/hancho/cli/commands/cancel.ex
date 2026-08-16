defmodule Hancho.CLI.Commands.Cancel do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, Operations, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([run_id, "--reason", reason], options) when reason != "" do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, work_order} <- Operations.cancel(repository, run_id, actor(), reason) do
      %Result{
        data: %{result: "cancelled", work_order: work_order},
        text: "#{run_id} cancelled: #{reason}"
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho cancel RUN_ID --reason TEXT"
  end

  defp actor, do: System.get_env("USER") || "local-user"
end
