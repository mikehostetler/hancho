defmodule Hancho.CLI.Commands.Show do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, ReadModel, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([run_id], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, data} <- ReadModel.show(repository, run_id) do
      work_order = data.work_order
      next = if data.next_action, do: "\nNext: #{data.next_action}", else: ""

      text =
        "#{work_order["id"]} #{work_order["state"]} status=#{work_order["status"]} events=#{length(data.events)} artifacts=#{length(data.artifacts)}#{next}"

      %Result{data: Map.put(data, :result, "ok"), text: text}
    else
      {:error, %Error{} = error} -> raise error
    end
  end
end
