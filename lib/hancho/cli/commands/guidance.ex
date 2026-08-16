defmodule Hancho.CLI.Commands.Guidance do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Config, Error, InstructionPacks, Repository}

  @impl true
  def execute(["show", workflow, station | rest], options) do
    design_work = rest == ["--design"]

    if rest not in [[], ["--design"]] do
      invalid!()
    end

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, config} <- Config.load(repository) do
      packs = InstructionPacks.resolve(config, workflow, station, %{design_work: design_work})

      text =
        Enum.map_join(packs, "\n", fn pack ->
          "#{pack.name}.v#{pack[:version] || "?"} #{pack.status} #{pack[:source] || pack[:reason]}"
        end)

      %Result{
        data: %{result: "ok", workflow: workflow, station: station, packs: safe(packs)},
        text: text
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options), do: invalid!()

  defp safe(packs), do: Enum.map(packs, &Map.drop(&1, [:pack]))

  defp invalid! do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho guidance show WORKFLOW STATION [--design]"
  end
end
