defmodule Hancho.GitTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Git, Repository}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {_, 0} = System.cmd("git", ["-C", root, "add", ".gitignore"])
    {_, 0} = System.cmd("git", ["-C", root, "commit", "-q", "-m", "Ignore Hancho state"])
    {:ok, repository} = Repository.discover(root)
    %{root: root, repository: repository}
  end

  test "checks clean preflight and detects a dirty control checkout", context do
    assert {:ok, %{baseline: baseline, branch: branch}} = Git.preflight(context.repository)
    assert String.length(baseline) == 40
    assert is_binary(branch)

    File.write!(Path.join(context.root, "dirty.txt"), "dirty")
    assert {:error, %{code: :dirty_control_checkout}} = Git.preflight(context.repository)
  end

  test "creates a worktree and checks exact and directory scopes", context do
    {:ok, preflight} = Git.preflight(context.repository)
    {:ok, worktree} = Git.prepare_worktree(context.repository, "run-scope", preflight.baseline)
    File.mkdir_p!(Path.join(worktree, "lib"))
    File.write!(Path.join(worktree, "lib/one.ex"), "one")

    assert {:ok, ["lib/one.ex"]} = Git.changed_paths(worktree)
    assert :ok = Git.verify_scope(["lib/one.ex"], ["lib/"])
    assert :ok = Git.verify_scope(["lib/one.ex"], ["lib/one.ex"])
    assert {:error, %{code: :scope_violation}} = Git.verify_scope(["lib/one.ex"], ["test/"])
    assert :ok = Git.remove_worktree(context.repository, worktree)
  end

  test "checks both source and destination of a rename", context do
    {:ok, preflight} = Git.preflight(context.repository)
    {:ok, worktree} = Git.prepare_worktree(context.repository, "run-rename", preflight.baseline)
    {_, 0} = System.cmd("git", ["-C", worktree, "mv", "README.md", "MOVED.md"])

    assert {:ok, paths} = Git.changed_paths(worktree)
    assert Enum.sort(paths) == ["MOVED.md", "README.md"]
    assert {:error, %{code: :scope_violation}} = Git.verify_scope(paths, ["MOVED.md"])
  end

  test "detects harness commits and creates a Hancho candidate", context do
    {:ok, preflight} = Git.preflight(context.repository)

    {:ok, worktree} =
      Git.prepare_worktree(context.repository, "run-candidate", preflight.baseline)

    File.write!(Path.join(worktree, "README.md"), "# Changed\n")

    assert {:ok, candidate} =
             Git.create_candidate(worktree, preflight.baseline, "run-candidate", "Change readme")

    assert {:error, %{code: :harness_git_effect}} = Git.assert_head(worktree, preflight.baseline)
    assert :ok = Git.retain_candidate(context.repository, "run-candidate", candidate)
    assert :ok = Git.assert_target_unchanged(context.repository, preflight.baseline)
  end
end
