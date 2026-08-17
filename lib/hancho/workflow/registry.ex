defmodule Hancho.Workflow.Registry do
  @moduledoc "Maps YAML action names to approved action modules."

  @actions %{
    "Hancho.Actions.Preflight" => Hancho.Actions.Preflight,
    "Hancho.Actions.ClaimIssue" => Hancho.Actions.ClaimIssue,
    "Hancho.Actions.CreateWorktree" => Hancho.Actions.CreateWorktree,
    "Hancho.Actions.RenderPrompt" => Hancho.Actions.RenderPrompt,
    "Hancho.Actions.Implement" => Hancho.Actions.Implement,
    "Hancho.Actions.Verify" => Hancho.Actions.Verify,
    "Hancho.Actions.Commit" => Hancho.Actions.Commit,
    "Hancho.Actions.Land" => Hancho.Actions.Land,
    "Hancho.Actions.RemoveWorktree" => Hancho.Actions.RemoveWorktree,
    "Hancho.Actions.CloseIssue" => Hancho.Actions.CloseIssue
  }

  @spec fetch(String.t()) :: {:ok, module()} | {:error, String.t()}
  def fetch(name) do
    case Map.fetch(@actions, name) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "Action is not approved: #{name}"}
    end
  end

  @spec actions() :: map()
  def actions, do: @actions
end
