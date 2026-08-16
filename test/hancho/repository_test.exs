defmodule Hancho.RepositoryTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{JSON, Repository, SQLite, Store}

  test "discovers a repository from a subdirectory" do
    root = temporary_git_repository!()
    child = Path.join(root, "one/two")
    File.mkdir_p!(child)

    assert {:ok, repository} = Repository.discover(child)
    assert repository.root == root
    assert repository.git_common_dir == Path.join(root, ".git")
    assert repository.branch in ["main", "master"]
  end

  test "rejects a path outside Git without creating files" do
    path = temporary_directory!("outside")
    assert {:error, error} = Repository.discover(path)
    assert error.code == :not_a_git_repository
    refute File.exists?(Path.join(path, ".hancho"))
  end

  test "initializes one ignored local runtime and preserves configuration" do
    root = temporary_git_repository!()
    assert {:ok, repository} = Repository.discover(root)
    assert {:ok, first} = Repository.init(repository)
    assert first.config == "created"

    config_path = Path.join(root, ".hancho/config.toml")
    File.write!(config_path, File.read!(config_path) <> "\n# local change\n")

    assert {:ok, repository} = Repository.discover(root)
    assert {:ok, second} = Repository.init(repository)
    assert second.config == "preserved"
    assert File.read!(config_path) =~ "# local change"

    ignore_count =
      root
      |> Path.join(".gitignore")
      |> File.read!()
      |> String.split("\n")
      |> Enum.count(&(String.trim(&1) in [".hancho/", "/.hancho/"]))

    assert ignore_count == 1
    assert {:ok, 3} = SQLite.scalar(Store.path(repository), "PRAGMA user_version;")

    identity = JSON.decode!(File.read!(Path.join(root, ".hancho/repository.json")))
    assert identity["repository_id"] == second.repository_id
  end

  test "reports linked worktree and common Git directory" do
    root = temporary_git_repository!("main")
    worktree = temporary_directory!("linked")

    {_, 0} =
      System.cmd("git", ["-C", root, "worktree", "add", "-q", "-b", "linked-test", worktree])

    assert {:ok, linked} = Repository.discover(worktree)
    assert linked.root == worktree
    assert linked.git_common_dir == Path.join(root, ".git")
  end
end
