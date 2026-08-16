defmodule Hancho.CLI.Commands.Measures do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Error, Measures, Repository}

  @impl true
  def execute([], options) do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, report} <- Measures.report(repository) do
      values = report.values

      %Result{
        data: Map.put(report, :result, "ok"),
        text:
          "WIP=#{values.active_wip} oldest=#{values.oldest_committed_age_seconds || "none"}s rework=#{values.rework_count} failed_delivery=#{values.failed_delivery_count}"
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options),
    do: raise(Error, code: :invalid_arguments, exit_status: 64, message: "Usage: hancho measures")
end
