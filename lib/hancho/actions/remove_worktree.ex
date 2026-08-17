defmodule Hancho.Actions.RemoveWorktree do
  @moduledoc "Removes the completed factory worktree."

  use Jido.Action,
    name: "hancho_remove_worktree",
    description: "Removes a Hancho-owned Git worktree",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        worktree_path: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context
  alias Hancho.Workflow.Effect

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)
    root = Path.expand(Path.join([params.repo_path, ".hancho", "worktrees"]))
    path = Path.expand(params.worktree_path)
    relative = Path.relative_to(path, root)

    case Path.safe_relative(relative, root) do
      {:ok, relative} when relative != "." ->
        receipt = %{worktree_path: path, removed: true}

        Effect.run(
          context,
          "remove",
          "git.worktree.remove",
          %{repository: params.repo_path, path: path},
          fn -> if(File.exists?(path), do: :not_applied, else: {:ok, receipt}) end,
          fn -> remove(git, params.repo_path, path, receipt) end
        )

      _other ->
        {:error, "Hancho refused to remove a path outside its worktree folder."}
    end
  end

  defp remove(git, repository, path, receipt) do
    case git.remove_worktree(repository, path) do
      {:ok, :done} -> {:ok, receipt}
      {:error, reason} -> {:error, reason}
    end
  end
end
