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

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)
    root = Path.expand(Path.join([params.repo_path, ".hancho", "worktrees"]))
    path = Path.expand(params.worktree_path)
    relative = Path.relative_to(path, root)

    case Path.safe_relative(relative, root) do
      {:ok, relative} when relative != "." ->
        case git.remove_worktree(params.repo_path, path) do
          {:ok, :done} -> {:ok, %{worktree_path: path, removed: true}}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, "Hancho refused to remove a path outside its worktree folder."}
    end
  end
end
