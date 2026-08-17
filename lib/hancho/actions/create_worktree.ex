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
  alias Hancho.Workflow.Effect

  @impl true
  def run(%{repo_path: repository, baseline: baseline, run_id: run_id}, context) do
    git = Context.service(context, :git, Hancho.Git)

    if Regex.match?(~r/^[A-Za-z0-9_-]+$/, run_id) do
      path = Path.join([repository, ".hancho", "worktrees", run_id])
      receipt = %{worktree_path: path, baseline: baseline}

      Effect.run(
        context,
        "create",
        "git.worktree.create",
        %{repository: repository, path: path, baseline: baseline},
        fn -> reconcile(git, path, baseline, receipt) end,
        fn -> create(git, repository, path, baseline, receipt) end
      )
    else
      {:error, "The workflow run ID is not safe for a path."}
    end
  end

  defp reconcile(git, path, baseline, receipt) do
    if File.exists?(path) do
      case git.head(working_dir: path) do
        {:ok, ^baseline} -> {:ok, receipt}
        {:ok, actual} -> {:error, {:worktree_head_changed, baseline, actual}}
        {:error, reason} -> {:error, reason}
      end
    else
      :not_applied
    end
  end

  defp create(git, repository, path, baseline, receipt) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, :done} <- git.create_worktree(repository, path, baseline) do
      {:ok, receipt}
    end
  end
end
