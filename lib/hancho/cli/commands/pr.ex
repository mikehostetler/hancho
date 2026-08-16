defmodule Hancho.CLI.Commands.PR do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Error, PullRequest, Repository}

  @impl true
  def execute([run_id | args], options) do
    pr_options = parse(args, [])

    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <- PullRequest.open(repository, run_id, pr_options) do
      %Result{
        data: Map.put(outcome, :result, "pull_request_ready"),
        text:
          "Pull request #{outcome.pull_request["url"] || outcome.pull_request["number"]} names #{outcome.pull_request["headRefOid"]}."
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options), do: invalid!()
  defp parse([], options), do: options
  defp parse(["--base", base | rest], options), do: parse(rest, Keyword.put(options, :base, base))

  defp parse(["--branch", branch | rest], options),
    do: parse(rest, Keyword.put(options, :branch, branch))

  defp parse(["--title", title | rest], options),
    do: parse(rest, Keyword.put(options, :title, title))

  defp parse(_args, _options), do: invalid!()

  defp invalid!,
    do:
      raise(Error,
        code: :invalid_arguments,
        exit_status: 64,
        message: "Usage: hancho pr RUN_ID [--base BRANCH] [--branch BRANCH] [--title TEXT]"
      )
end
