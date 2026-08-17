defmodule Hancho.Actions.CreateWorktree do
  @moduledoc "Creates a detached worktree for one factory run."

  use Jido.Action,
    name: "hancho_create_worktree",
    description: "Creates an isolated Git worktree",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        baseline: Zoi.string() |> Zoi.min(1),
        run_id: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context

  @impl true
  def run(%{repo_path: repository, baseline: baseline, run_id: run_id}, context) do
    git = Context.service(context, :git, Hancho.Git)

    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, run_id) do
      path = Path.join([repository, ".hancho", "worktrees", run_id])

      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, :done} <- git.create_worktree(repository, path, baseline) do
        {:ok, %{worktree_path: path, baseline: baseline}}
      end
    else
      {:error, "The workflow run ID is not safe for a path."}
    end
  end
end
