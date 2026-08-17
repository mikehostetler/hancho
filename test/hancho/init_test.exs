defmodule Hancho.InitTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  defmodule MissingGitProjectAPI do
    def discover(_options), do: {:error, :git_not_found}
  end

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

    assert values["logs"] == %{
             "compress" => true,
             "console" => true,
             "enabled" => true,
             "format" => "jsonl",
             "include_internal" => false,
             "max_bytes" => 10_485_760,
             "max_files" => 5,
             "path" => "factory.jsonl",
             "sync_interval_ms" => 1_000
           }

    assert File.dir?(Path.join(repository, ".hancho/logs"))
    assert File.dir?(Path.join(repository, ".hancho/prompts"))
    assert File.dir?(Path.join(repository, ".hancho/workflows"))
    assert File.dir?(Path.join(repository, ".hancho/worktrees"))

    assert File.read!(Path.join(repository, ".hancho/workflows/implement.yaml")) =~
             "action: Hancho.Actions.Preflight"

    prompt = Path.join(repository, ".hancho/prompts/implement.md")
    assert File.read!(prompt) =~ "Implement Beadwork task {{issue.id}}"

    assert File.read!(Path.join(repository, ".gitignore")) == "_build/\n/.hancho/\n"

    File.write!(config, "version = 1\nname = \"custom\"\n")
    workflow = Path.join(repository, ".hancho/workflows/implement.yaml")
    File.write!(workflow, "name: custom\n")
    File.write!(prompt, "Custom prompt\n")
    assert {:ok, path} = Hancho.Init.run(options)
    assert String.ends_with?(path, "/#{Path.basename(repository)}/.hancho")
    assert File.read!(config) == "version = 1\nname = \"custom\"\n"
    assert File.read!(workflow) == "name: custom\n"
    assert File.read!(prompt) == "Custom prompt\n"
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

  test "reports when Git is not installed" do
    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(["init"], project_api: MissingGitProjectAPI) == 1
      end)

    assert output == "ERROR: Git executable not found in PATH.\n"
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-init-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
