defmodule Hancho.CLI.Commands.Work do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.WorkSource.Beadwork
  alias Hancho.{Error, Repository}

  @impl true
  def execute(["ready" | args], options) do
    selection = parse(args, [])

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, items} <- Beadwork.list_all(repository) do
      view = Beadwork.selection_view(items, selection)

      text =
        Enum.map_join(
          view.explanations,
          "\n",
          &"#{&1.id} #{if &1.selected, do: "ready", else: "skip"} — #{&1.reason}"
        )

      %Result{data: Map.put(view, :result, "ok"), text: text}
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options), do: invalid!()
  defp parse([], options), do: options
  defp parse(["--only", id | rest], options), do: parse(rest, Keyword.put(options, :only, id))

  defp parse(["--max", count | rest], options),
    do: parse(rest, Keyword.put(options, :max, integer!(count)))

  defp parse(["--start-at", id | rest], options),
    do: parse(rest, Keyword.put(options, :start_at, id))

  defp parse(["--end-at", id | rest], options), do: parse(rest, Keyword.put(options, :end_at, id))

  defp parse(["--include-blocked" | rest], options),
    do: parse(rest, Keyword.put(options, :include_blocked, true))

  defp parse(["--include-closed" | rest], options),
    do: parse(rest, Keyword.put(options, :include_closed, true))

  defp parse(["--dry-run" | rest], options), do: parse(rest, Keyword.put(options, :dry_run, true))
  defp parse(_args, _options), do: invalid!()

  defp integer!(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> number
      _ -> invalid!()
    end
  end

  defp invalid!,
    do:
      raise(Error,
        code: :invalid_arguments,
        exit_status: 64,
        message:
          "Usage: hancho work ready [--only ID] [--start-at ID] [--end-at ID] [--max N] [--include-blocked] [--include-closed] [--dry-run]"
      )
end
