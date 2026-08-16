defmodule Hancho.InitTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "initializes a repository and does not replace its configuration" do
    repository = temporary_directory()
    File.write!(Path.join(repository, ".gitignore"), "_build/\n")

    options = options(repository)

    assert capture_io(fn -> assert Hancho.CLI.run(["init"], options) == 0 end) ==
             "Initialized Hancho at #{repository}/.hancho\n"

    config = Path.join(repository, ".hancho/config.toml")
    assert File.read!(config) == "version = 1\n"
    assert File.dir?(Path.join(repository, ".hancho/logs"))
    assert File.dir?(Path.join(repository, ".hancho/state"))
    assert File.read!(Path.join(repository, ".gitignore")) == "_build/\n/.hancho/\n"

    File.write!(config, "version = 1\nname = \"custom\"\n")
    assert Hancho.Init.run(options) == {:ok, Path.join(repository, ".hancho")}
    assert File.read!(config) == "version = 1\nname = \"custom\"\n"
    assert File.read!(Path.join(repository, ".gitignore")) == "_build/\n/.hancho/\n"
  end

  test "rejects a directory outside a Git repository" do
    directory = temporary_directory()
    command = fn _git, _arguments, _options -> {"not a repository", 128} end

    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(
                 ["init"],
                 cwd: directory,
                 command: command,
                 find_executable: fn "git" -> "/usr/bin/git" end
               ) == 1
      end)

    assert output == "ERROR: Current directory is not in a Git repository.\n"
    refute File.exists?(Path.join(directory, ".hancho"))
  end

  defp options(repository) do
    [
      cwd: repository,
      command: fn _git, _arguments, _options -> {repository <> "\n", 0} end,
      find_executable: fn "git" -> "/usr/bin/git" end
    ]
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-init-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
