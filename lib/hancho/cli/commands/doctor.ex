defmodule Hancho.CLI.Commands.Doctor do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.{Doctor, Error, Repository}
  alias Hancho.CLI.Result

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())) do
      data = Doctor.run(repository)

      text =
        data.checks
        |> Enum.map_join("\n", fn check ->
          "#{String.upcase(check.status)} #{check.name}: #{check.detail}"
        end)

      %Result{data: data, text: text, status: if(data.result == "ok", do: 0, else: 78)}
    else
      {:error, %Error{} = error} -> raise error
    end
  end
end
