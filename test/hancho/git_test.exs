defmodule Hancho.GitTest do
  use ExUnit.Case, async: false

  test "reads repository data through the Hancho Git interface" do
    repository = temporary_repository()
    File.write!(Path.join(repository, "new.txt"), "new\n")

    assert {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    assert File.dir?(root)
    assert Path.basename(root) == Path.basename(repository)

    assert {:ok, %Git.Status{branch: "main", entries: entries}} =
             Hancho.Git.status(working_dir: repository)

    assert entries == [%{index: "?", working_tree: "?", path: "new.txt"}]

    assert {:ok, worktrees} = Hancho.Git.worktrees(working_dir: repository)
    assert Enum.any?(worktrees, &(Path.expand(&1.path) == Path.expand(root)))
  end

  test "supports Git commands that read standard input" do
    repository = temporary_repository()
    config = Hancho.Git.config(working_dir: repository)

    assert Git.mktree(config: config) ==
             {:ok, "4b825dc642cb6eb9a060e54bf8d69288fbee4904"}
  end

  test "creates unsigned factory commits when repository signing is enabled" do
    repository = temporary_repository()
    File.write!(Path.join(repository, "change.txt"), "change\n")

    {_output, 0} = System.cmd("git", ["-C", repository, "config", "commit.gpgsign", "true"])

    assert {:ok, :done} = Hancho.Git.add_all(repository)
    assert {:ok, %Git.CommitResult{}} = Hancho.Git.commit(repository, "Factory commit")
  end

  defp temporary_repository do
    path = Path.join(System.tmp_dir!(), "hancho-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "-c",
        "commit.gpgsign=false",
        "commit",
        "--allow-empty",
        "-m",
        "Initial commit"
      ])

    path
  end
end
