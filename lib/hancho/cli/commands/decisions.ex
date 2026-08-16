defmodule Hancho.CLI.Commands.Decisions do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, Journal, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, decisions} <- Journal.open_decisions(repository) do
      text =
        Enum.map_join(
          decisions,
          "\n",
          &"#{&1["id"]} run=#{&1["run_id"]} kind=#{&1["kind"]}"
        )

      %Result{data: %{result: "ok", decisions: decisions}, text: text}
    else
      {:error, %Error{} = error} -> raise error
    end
  end
end
