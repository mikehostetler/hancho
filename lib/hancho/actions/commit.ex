defmodule Hancho.Actions.Commit do
  @moduledoc "Creates the implementation commit in the detached worktree."

  use Jido.Action,
    name: "hancho_commit",
    description: "Commits verified work",
    schema:
      Zoi.object(%{
        worktree_path: Zoi.string() |> Zoi.min(1),
        baseline: Zoi.string() |> Zoi.min(1),
        issue: Zoi.map()
      })

  alias Hancho.Actions.Context

  @impl true
  def run(params, context) do
    git = Context.service(context, :git, Hancho.Git)
    issue_id = params.issue["id"] || params.issue[:id]
    title = params.issue["title"] || params.issue[:title] || issue_id

    message = "feat: implement #{issue_id}\n\n#{title}\n\nBeadwork-ID: #{issue_id}"

    with {:ok, head} <- git.head(working_dir: params.worktree_path),
         :ok <- unchanged_head(head, params.baseline),
         {:ok, status} <- git.status(working_dir: params.worktree_path),
         :ok <- has_changes(status),
         {:ok, :done} <- git.add_all(params.worktree_path),
         {:ok, commit} <- git.commit(params.worktree_path, message) do
      {:ok, %{commit: commit.full_hash, issue_id: issue_id}}
    end
  end

  defp unchanged_head(head, head), do: :ok

  defp unchanged_head(_head, _baseline),
    do: {:error, "The coding agent created commits. Hancho requires uncommitted changes."}

  defp has_changes(%Git.Status{entries: []}), do: {:error, "There are no changes to commit."}
  defp has_changes(_status), do: :ok
end
