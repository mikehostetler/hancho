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
  end

  test "supports Git commands that read standard input" do
    repository = temporary_repository()
    config = Hancho.Git.config(working_dir: repository)

    assert Git.mktree(config: config) ==
             {:ok, "4b825dc642cb6eb9a060e54bf8d69288fbee4904"}
  end

  test "returns command output and nonzero exit status" do
    assert Hancho.Git.Runner.run(
             "/bin/sh",
             ["-c", "printf failure >&2; exit 7"],
             timeout: 1_000,
             stderr_to_stdout: true
           ) == {:ok, {"failure", 7}}
  end

  test "stops a command when it reaches its timeout" do
    assert Hancho.Git.Runner.run(
             "/bin/sh",
             ["-c", "sleep 10"],
             timeout: 20,
             stderr_to_stdout: true
           ) == {:error, :timeout}
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
        "commit",
        "--allow-empty",
        "-m",
        "Initial commit"
      ])

    path
  end
end
