defmodule Hancho.Workflow.Artifacts do
  @moduledoc "Maps approved action outputs to stable factory roles."

  @roles %{
    "Hancho.Actions.Preflight" => "repository",
    "Hancho.Actions.Implement" => "implementation",
    "Hancho.Actions.Verify" => "verification",
    "Hancho.Actions.Commit" => "commit",
    "Hancho.Actions.Land" => "landing",
    "Hancho.Actions.CreateWorktree" => "worktree_created",
    "Hancho.Actions.UseRepository" => "workspace_opened",
    "Hancho.Actions.RemoveWorktree" => "worktree_removed",
    "Hancho.Actions.CloseIssue" => "issue_closed"
  }

  @spec put(map(), String.t(), map()) :: map()
  def put(artifacts, action, result) do
    case Map.fetch(@roles, action) do
      {:ok, role} -> Map.put(artifacts, role, result)
      :error -> artifacts
    end
  end

  @spec from_outputs(Hancho.Workflow.Definition.t(), map()) :: map()
  def from_outputs(definition, outputs) do
    Enum.reduce(definition.steps, %{}, fn step, artifacts ->
      case Map.fetch(outputs, step.name) do
        {:ok, result} -> put(artifacts, step.action, result)
        :error -> artifacts
      end
    end)
  end

  @spec from_steps([map()], map()) :: map()
  def from_steps(steps, outputs) do
    Enum.reduce(steps, %{}, fn step, artifacts ->
      case Map.fetch(outputs, step["name"]) do
        {:ok, result} -> put(artifacts, step["action"], result)
        :error -> artifacts
      end
    end)
  end

  @spec fetch(map(), String.t()) :: map() | nil
  def fetch(artifacts, role), do: Map.get(artifacts, role)
end
