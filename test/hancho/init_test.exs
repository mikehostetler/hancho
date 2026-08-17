defmodule Hancho.InitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "initializes a repository and does not replace its configuration" do
    repository = temporary_directory()
    {_output, 0} = System.cmd("git", ["init", repository])
    File.write!(Path.join(repository, ".gitignore"), "_build/\n")

    options = [cwd: repository]

    output = capture_io(fn -> assert Hancho.CLI.run(["init"], options) == 0 end)
    assert output =~ "Initialized Hancho at "
    assert String.ends_with?(output, "/#{Path.basename(repository)}/.hancho\n")

    config = Path.join(repository, ".hancho/config.toml")
    assert {:ok, values} = config |> File.read!() |> TomlElixir.decode()
    assert values["version"] == 1
    assert Path.basename(values["repo"]["path"]) == Path.basename(repository)
    assert File.dir?(Path.join(repository, ".hancho/logs"))
    assert File.dir?(Path.join(repository, ".hancho/state"))
    assert File.read!(Path.join(repository, ".gitignore")) == "_build/\n/.hancho/\n"

    File.write!(config, "version = 1\nname = \"custom\"\n")
    assert {:ok, path} = Hancho.Init.run(options)
    assert String.ends_with?(path, "/#{Path.basename(repository)}/.hancho")
    assert File.read!(config) == "version = 1\nname = \"custom\"\n"
    assert File.read!(Path.join(repository, ".gitignore")) == "_build/\n/.hancho/\n"
  end

  test "rejects a directory outside a Git repository" do
    directory = temporary_directory()

    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(["init"], cwd: directory) == 1
      end)

    assert output == "ERROR: Current directory is not in a Git repository.\n"
    refute File.exists?(Path.join(directory, ".hancho"))
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-init-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
