defmodule Hancho.CLI.Commands.Runs do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, Journal, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, work_orders} <- Journal.list_work_orders(repository) do
      text =
        Enum.map_join(
          work_orders,
          "\n",
          &"#{&1["id"]} #{&1["workflow_name"]}.v#{&1["workflow_version"]} #{&1["state"]} #{&1["work_ref"]}"
        )

      %Result{data: %{result: "ok", work_orders: work_orders}, text: text}
    else
      {:error, %Error{} = error} -> raise error
    end
  end
end
