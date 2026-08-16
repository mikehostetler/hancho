defmodule Hancho.CLI.Commands.Cleanup do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.{Cleanup, Error, Repository}

  @impl true
  def execute(args, options) when args in [[], ["--apply"]] do
    with {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, outcome} <- Cleanup.run(repository, apply: args == ["--apply"]) do
      %Result{
        data: Map.put(outcome, :result, outcome.mode),
        text:
          "Cleanup #{outcome.mode}: #{length(outcome.artifact_candidates)} artifact candidates and #{length(outcome.worktree_candidates)} worktree candidates; #{length(outcome.removed)} removed."
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho cleanup [--apply]"
  end
end
