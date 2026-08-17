defmodule Hancho.WorktreesTest do
  use ExUnit.Case, async: false

  alias Hancho.Worktrees

  test "lists, inspects, and safely cleans generated worktree artifacts" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    File.mkdir_p!(project.worktrees_path)
    {:ok, head} = Hancho.Git.head(working_dir: repository)
    path = Path.join(project.worktrees_path, "run-retained")
    assert {:ok, :done} = Hancho.Git.create_worktree(repository, path, head)

    File.mkdir_p!(Path.join(path, "_build"))
    File.mkdir_p!(Path.join(path, "deps"))
    File.mkdir_p!(Path.join(path, "cover"))
    File.write!(Path.join(path, "_build/artifact.beam"), String.duplicate("b", 20))
    File.write!(Path.join(path, "deps/dependency.bin"), String.duplicate("d", 30))
    File.write!(Path.join(path, "cover/results.html"), String.duplicate("c", 40))
    File.write!(Path.join(path, "feature.txt"), "diagnostic source change\n")

    assert {:ok, [listed]} = Worktrees.list(project)
    assert listed.id == "run-retained"
    assert listed.registered
    assert listed.detached
    refute listed.clean
    assert listed.generated_bytes == 90
    assert "feature.txt" in listed.changed_paths

    assert {:ok, inspected} = Worktrees.inspect(project, "run-retained")
    assert inspected.path == path
    assert inspected.size_bytes >= inspected.generated_bytes

    assert {:ok, cleaned} = Worktrees.clean(project, "run-retained")
    assert cleaned.removed == ["_build", "deps", "cover"]
    assert cleaned.reclaimed_bytes == 90
    assert cleaned.source_changes_retained
    assert File.read!(Path.join(path, "feature.txt")) == "diagnostic source change\n"
    refute File.exists?(Path.join(path, "_build"))
    refute File.exists?(Path.join(path, "deps"))
    refute File.exists?(Path.join(path, "cover"))

    assert {:ok, registrations} = Hancho.Git.worktrees(working_dir: repository)
    assert Enum.any?(registrations, &(&1.head == head and &1.detached))

    assert {:error, :invalid_worktree_id} = Worktrees.inspect(project, "../outside")
  end

  defp temporary_repository do
    path = Path.join(System.tmp_dir!(), "hancho-worktrees-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", ".gitignore"])

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
        "chore: initialize repository"
      ])

    path
  end
end
