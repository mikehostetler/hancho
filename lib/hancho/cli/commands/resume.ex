defmodule Hancho.CLI.Commands.Resume do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, Operations, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([run_id], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <- Operations.resume(repository, run_id) do
      work_order = outcome.work_order

      %Result{
        data: %{result: work_order["status"], work_order: work_order},
        text: "#{run_id} resumed to #{work_order["state"]}",
        status: if(work_order["status"] == "complete", do: 0, else: 75)
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error, code: :invalid_arguments, exit_status: 64, message: "Usage: hancho resume RUN_ID"
  end
end
