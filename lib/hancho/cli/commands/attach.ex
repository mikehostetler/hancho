defmodule Hancho.CLI.Commands.Attach do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.Host.Tmux
  alias Hancho.{Error, Repository}

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, :attached} <- Tmux.attach(repository) do
      %Result{data: %{result: "detached"}, text: "Detached from the Hancho tmux session."}
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error, code: :invalid_arguments, exit_status: 64, message: "Usage: hancho attach"
  end
end
