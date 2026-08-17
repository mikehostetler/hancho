defmodule Hancho.ActionsTest do
  use ExUnit.Case, async: false

  alias Hancho.Actions
  alias Hancho.Command.Result

  defmodule PreflightGit do
    def status(_options), do: {:ok, %Git.Status{branch: "main", entries: []}}
    def head(_options), do: {:ok, "abc123"}
  end

  defmodule PreflightBeadwork do
    def show("hancho-123", _options) do
      {:ok,
       %{
         "id" => "hancho-123",
         "title" => "Test task",
         "type" => "task",
         "status" => "open",
         "blocked_by" => []
       }}
    end
  end

  defmodule Harness do
    def run(:codex, prompt, options) do
      if prompt =~ "hancho-123" and
           options[:cwd] == "/repo/.hancho/worktrees/run-1" and
           options[:sandbox_mode] == :workspace_write and
           options[:approval_mode] == :auto_edit do
        {:ok,
         Jido.Harness.RunResult.new!(%{
           run_id: "harness-1",
           provider: :codex,
           status: :completed,
           text: "implemented"
         })}
      else
        {:error, :invalid_harness_request}
      end
    end
  end

  defmodule Command do
    def run("/test/mix", ["test"], options) do
      if options[:cwd] == "/repo/worktree" do
        {:ok, %Result{stdout: "2 tests, 0 failures\n", stderr: "", exit_status: 0}}
      else
        {:error, :invalid_command_options}
      end
    end
  end

  test "executes preflight through Jido.Action validation" do
    context = %{services: %{git: PreflightGit, beadwork: PreflightBeadwork}}

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Preflight,
               %{repo_path: "/repo", issue_id: "hancho-123"},
               context
             )

    assert result.baseline == "abc123"
    assert result.branch == "main"
    assert result.issue["id"] == "hancho-123"
  end

  test "calls Jido.Harness with an approved provider and isolated worktree" do
    issue = %{"id" => "hancho-123", "title" => "Test", "description" => "Do work"}

    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Implement,
               %{
                 issue: issue,
                 worktree_path: "/repo/.hancho/worktrees/run-1",
                 provider: "codex",
                 timeout_ms: 1_000
               },
               %{services: %{harness: Harness}}
             )

    assert result.status == :completed
    assert result.harness_run_id == "harness-1"
  end

  test "runs the configured verification command and captures its output" do
    assert {:ok, result} =
             Jido.Exec.run(
               Actions.Verify,
               %{
                 worktree_path: "/repo/worktree",
                 executable: "/test/mix",
                 arguments: ["test"],
                 timeout_ms: 1_000
               },
               %{services: %{command: Command}, log: :disabled}
             )

    assert result.exit_status == 0
    assert result.output =~ "0 failures"
  end

  test "creates, commits, lands, and removes a real detached worktree" do
    repository = temporary_repository()
    {:ok, baseline} = Hancho.Git.head(working_dir: repository)
    context = %{services: %{git: Hancho.Git}}

    assert {:ok, created} =
             Jido.Exec.run(
               Actions.CreateWorktree,
               %{repo_path: repository, baseline: baseline, run_id: "run-1"},
               context
             )

    File.write!(Path.join(created.worktree_path, "feature.txt"), "factory\n")

    issue = %{"id" => "hancho-123", "title" => "Add factory feature"}

    assert {:ok, committed} =
             Jido.Exec.run(
               Actions.Commit,
               %{worktree_path: created.worktree_path, baseline: baseline, issue: issue},
               context
             )

    assert committed.commit != baseline

    assert {:ok, landed} =
             Jido.Exec.run(
               Actions.Land,
               %{repo_path: repository, baseline: baseline, commit: committed.commit},
               context
             )

    assert landed.commit == committed.commit
    assert File.read!(Path.join(repository, "feature.txt")) == "factory\n"

    assert {:ok, removed} =
             Jido.Exec.run(
               Actions.RemoveWorktree,
               %{repo_path: repository, worktree_path: created.worktree_path},
               context
             )

    assert removed.removed
    refute File.exists?(created.worktree_path)
  end

  defp temporary_repository do
    path = Path.join(System.tmp_dir!(), "hancho-actions-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "add",
        ".gitignore"
      ])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "commit",
        "-m",
        "chore: initialize test repository"
      ])

    path
  end
end
