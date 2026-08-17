defmodule Hancho.Workflow.Default do
  @moduledoc false

  @implementation """
  name: implement
  version: 1
  steps:
    - name: preflight
      action: Hancho.Actions.Preflight
      params:
        repo_path: "$input.repo_path"
        issue_id: "$input.issue_id"
    - name: claim
      action: Hancho.Actions.ClaimIssue
      params:
        repo_path: "$steps.preflight.repo_path"
        issue: "$steps.preflight.issue"
    - name: create_worktree
      action: Hancho.Actions.CreateWorktree
      params:
        repo_path: "$steps.preflight.repo_path"
        baseline: "$steps.preflight.baseline"
        run_id: "$run.id"
    - name: implement
      action: Hancho.Actions.Implement
      params:
        issue: "$steps.claim.issue"
        worktree_path: "$steps.create_worktree.worktree_path"
        provider: codex
        timeout_ms: 1800000
    - name: verify
      action: Hancho.Actions.Verify
      params:
        worktree_path: "$steps.create_worktree.worktree_path"
        executable: mix
        arguments:
          - test
        timeout_ms: 600000
    - name: commit
      action: Hancho.Actions.Commit
      params:
        worktree_path: "$steps.create_worktree.worktree_path"
        baseline: "$steps.preflight.baseline"
        issue: "$steps.claim.issue"
    - name: land
      action: Hancho.Actions.Land
      params:
        repo_path: "$steps.preflight.repo_path"
        baseline: "$steps.preflight.baseline"
        commit: "$steps.commit.commit"
    - name: remove_worktree
      action: Hancho.Actions.RemoveWorktree
      params:
        repo_path: "$steps.preflight.repo_path"
        worktree_path: "$steps.create_worktree.worktree_path"
    - name: close_issue
      action: Hancho.Actions.CloseIssue
      params:
        repo_path: "$steps.preflight.repo_path"
        issue_id: "$steps.claim.issue.id"
        commit: "$steps.commit.commit"
  """

  @spec install(Hancho.Project.t()) :: :ok | {:error, term()}
  def install(project) do
    path = Path.join(project.workflows_path, "implement.yaml")

    if File.exists?(path) do
      :ok
    else
      File.write(path, @implementation)
    end
  end

  @spec implementation() :: String.t()
  def implementation, do: @implementation
end
