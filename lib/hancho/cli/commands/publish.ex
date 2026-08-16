defmodule Hancho.CLI.Commands.Publish do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Error, Publication, Repository}

  @impl true
  def execute([run_id | args], options) do
    publish_options = parse(args, [])

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <- Publication.publish(repository, run_id, publish_options) do
      %Result{
        data: Map.put(outcome, :result, "published"),
        text: "Published #{outcome.candidate_commit} to #{outcome.remote}/#{outcome.branch}."
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options), do: invalid!()
  defp parse([], options), do: options

  defp parse(["--remote", remote | rest], options),
    do: parse(rest, Keyword.put(options, :remote, remote))

  defp parse(["--branch", branch | rest], options),
    do: parse(rest, Keyword.put(options, :branch, branch))

  defp parse(_args, _options), do: invalid!()

  defp invalid!,
    do:
      raise(Error,
        code: :invalid_arguments,
        exit_status: 64,
        message: "Usage: hancho publish RUN_ID [--remote NAME] [--branch NAME]"
      )
end
