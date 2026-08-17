defmodule Hancho.Actions.UseRepository do
  @moduledoc "Selects the clean repository checkout as the implementation workspace."

  use Jido.Action,
    name: "hancho_use_repository",
    description: "Uses the attached repository checkout without a Git worktree",
    schema:
      Zoi.object(%{
        repo_path: Zoi.string() |> Zoi.min(1),
        baseline: Zoi.string() |> Zoi.min(1)
      })

  alias Hancho.Actions.Context

  @impl true
  def run(%{repo_path: repository, baseline: baseline}, context) do
    git = Context.service(context, :git, Hancho.Git)

    with {:ok, status} <- git.status(working_dir: repository, untracked_files: :all),
         :ok <- clean(status),
         {:ok, head} <- git.head(working_dir: repository),
         :ok <- same_head(head, baseline) do
      {:ok,
       %{
         mode: "in_place",
         workspace_path: Path.expand(repository),
         baseline: baseline
       }}
    end
  end

  defp clean(%Git.Status{entries: []}), do: :ok
  defp clean(_status), do: {:error, "The in-place workspace has uncommitted changes."}

  defp same_head(head, head), do: :ok
  defp same_head(_head, _baseline), do: {:error, "The in-place workspace HEAD changed."}
end
