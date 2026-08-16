defmodule Hancho.CLI.Commands.Merge do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Error, Merge, Repository}

  @impl true
  def execute([run_id, pull_request | args], options) do
    merge_options = parse(args, [])

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <- Merge.merge(repository, run_id, pull_request, merge_options) do
      commit = get_in(outcome.observation, ["mergeCommit", "oid"])

      %Result{
        data: Map.put(outcome, :result, "merged"),
        text: "Merged exact candidate as #{commit}."
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options), do: invalid!()
  defp parse([], options), do: options

  defp parse(["--remote", remote | rest], options),
    do: parse(rest, Keyword.put(options, :remote, remote))

  defp parse(["--revalidated-target", commit | rest], options),
    do: parse(rest, Keyword.put(options, :revalidated_target, commit))

  defp parse(["--policy-no-separate-authority" | rest], options),
    do: parse(rest, Keyword.put(options, :require_authority, false))

  defp parse(["--policy-no-review" | rest], options),
    do: parse(rest, Keyword.put(options, :require_review, false))

  defp parse(_args, _options), do: invalid!()

  defp invalid!,
    do:
      raise(Error,
        code: :invalid_arguments,
        exit_status: 64,
        message: "Usage: hancho merge RUN_ID PR [--revalidated-target SHA]"
      )
end
