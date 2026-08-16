defmodule Hancho.CLI.Commands.Init do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Error, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, data} <- Repository.init(repository) do
      %Result{
        data: data,
        text:
          "Initialized Hancho at #{data.runtime_dir}. Configuration: #{data.config}. Git ignore: #{data.gitignore}."
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end
end
