defmodule Hancho.CLI.Commands.Kaizen do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Error, Kaizen, Repository}

  @impl true
  def execute(["list"], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, proposals} <- Kaizen.list(repository) do
      text =
        Enum.map_join(
          proposals,
          "\n",
          &"#{&1["id"]} v#{&1["version"]} #{&1["status"]} #{&1["proposal"]}"
        )

      %Result{
        data: %{result: "ok", proposals: proposals},
        text: if(text == "", do: "No standard-work proposals.", else: text)
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(["evaluate", proposal_id, "--result", result], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, proposal} <- Kaizen.evaluate(repository, proposal_id, result) do
      %Result{data: %{result: "evaluated", proposal: proposal}, text: "Evaluated #{proposal_id}."}
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options),
    do:
      raise(Error,
        code: :invalid_arguments,
        exit_status: 64,
        message: "Usage: hancho kaizen list | hancho kaizen evaluate ID --result TEXT"
      )
end
