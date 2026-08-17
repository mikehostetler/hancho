defmodule Hancho.Workflow.FailureCleanup do
  @moduledoc "Removes generated data while it keeps a stopped run's source changes."

  alias Hancho.Workflow.Result

  @spec run(Hancho.Project.t(), Result.t(), keyword()) :: map() | nil
  def run(project, result, options \\ [])

  def run(project, %Result{status: :stopped, artifacts: artifacts}, options) do
    worktrees = Keyword.get(options, :worktrees, Hancho.Worktrees)

    case retained_worktree(artifacts) do
      nil ->
        nil

      path ->
        id = Path.basename(path)

        case worktrees.clean(project, id, options) do
          {:ok, cleanup} ->
            cleanup
            |> Map.put(:status, "completed")
            |> Hancho.Log.Event.normalize()

          {:error, reason} ->
            %{
              status: "failed",
              worktree_path: path,
              error: Hancho.Log.Event.normalize(reason),
              source_changes_retained: true
            }
        end
    end
  end

  def run(_project, _result, _options), do: nil

  defp retained_worktree(artifacts) do
    case {artifacts["worktree_created"], artifacts["worktree_removed"]} do
      {%{"worktree_path" => path}, nil} -> path
      _other -> nil
    end
  end
end
