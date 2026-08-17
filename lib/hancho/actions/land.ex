defmodule Hancho.Actions.Land do
  @moduledoc "Fast-forwards the original branch to the verified commit."

  use Jido.Action,
    name: "hancho_land",
    description: "Lands the implementation with a fast-forward merge",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        baseline: Zoi.string() |> Zoi.min(1),
        commit: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)

    with {:ok, status} <- git.status(working_dir: params.repo_path),
         :ok <- clean(status),
         {:ok, head} <- git.head(working_dir: params.repo_path),
         :ok <- same_baseline(head, params.baseline),
         {:ok, _result} <- git.merge_ff_only(params.repo_path, params.commit),
         {:ok, landed} <- git.head(working_dir: params.repo_path) do
      {:ok, %{commit: landed}}
    end
  end

  defp clean(%Git.Status{entries: []}), do: :ok
  defp clean(_status), do: {:error, "The landing worktree has uncommitted changes."}

  defp same_baseline(head, head), do: :ok
  defp same_baseline(_head, _baseline), do: {:error, "The landing branch changed during the run."}
end
