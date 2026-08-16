defmodule Hancho.CLI.Commands.Queue do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.Factory.{Client, Store}
  alias Hancho.{Error, Repository}

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, items} <- items(repository) do
      text =
        Enum.map_join(
          items,
          "\n",
          &"#{&1["id"]} #{&1["status"]} #{&1["workflow_name"]} #{&1["work_ref"]}"
        )

      %Result{
        data: %{result: "ok", items: items},
        text: if(text == "", do: "Queue is empty.", else: text)
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error, code: :invalid_arguments, exit_status: 64, message: "Usage: hancho queue"
  end

  defp items(repository) do
    case Client.request(repository, "queue", %{}, 500) do
      {:ok, %{"items" => items}} -> {:ok, items}
      {:error, _error} -> Store.list(repository)
    end
  end
end
