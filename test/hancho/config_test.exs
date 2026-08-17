defmodule Hancho.ConfigTest do
  use ExUnit.Case, async: true

  alias Hancho.Config
  alias Hancho.Config.Error
  alias Hancho.Project

  test "returns a validated repository default when the file does not exist" do
    project = temporary_project()

    assert {:ok, %Config{} = config} = Config.load(project)
    assert config.version == 1
    assert config.repo.path == project.root
    assert config.logs.enabled
    assert config.logs.path == "factory.jsonl"
    assert config.logs.format == :jsonl
    assert config.logs.console
    refute config.logs.include_internal
    assert config.logs.sync_interval_ms == 1_000
    assert config.logs.max_bytes == 10_485_760
    assert config.logs.max_files == 5
    assert config.logs.compress
    assert Config.get(config, "version") == 1
    assert Config.get(config, "repo.path") == project.root
    assert Config.get(config, "logs.format") == :jsonl
  end

  test "rejects a configured path outside the discovered repository" do
    project = temporary_project()
    write_config(project, "version = 1\nrepo.path = \"factory\"\n")

    assert {:error, %Error{kind: :validation} = error} = Config.load(project)
    assert error.message =~ "repo.path"
    assert error.message =~ "discovered Git repository root"
  end

  test "applies field defaults to a partial file" do
    project = temporary_project()
    write_config(project, "version = 1\n")

    assert {:ok, config} = Config.load(project)
    assert config.repo.path == project.root
    assert config.logs.path == "factory.jsonl"
  end

  test "reads logging options" do
    project = temporary_project()

    write_config(
      project,
      """
      version = 1

      [logs]
      enabled = false
      path = "runs/activity.log"
      format = "text"
      console = false
      include_internal = true
      sync_interval_ms = 0
      max_bytes = 2048
      max_files = 2
      compress = false
      """
    )

    assert {:ok, config} = Config.load(project)
    refute config.logs.enabled
    assert config.logs.path == "runs/activity.log"
    assert config.logs.format == :text
    refute config.logs.console
    assert config.logs.include_internal
    assert config.logs.sync_interval_ms == 0
    assert config.logs.max_bytes == 2048
    assert config.logs.max_files == 2
    refute config.logs.compress
  end

  test "rejects logging paths outside the local log directory" do
    project = temporary_project()

    for path <- ["../factory.log", "/tmp/factory.log", "."] do
      write_config(project, "version = 1\nlogs.path = #{inspect(path)}\n")

      assert {:error, %Error{kind: :validation} = error} = Config.load(project)
      assert error.message =~ "logs.path"
    end
  end

  test "provides default values for missing lookup keys" do
    project = temporary_project()
    {:ok, config} = Config.default(project)

    assert Config.fetch(config, "repo.missing") == :error
    assert Config.get(config, "repo.missing") == nil
    assert Config.get(config, "repo.missing", "fallback") == "fallback"
    assert Config.fetch(config, ".repo.path") == :error
    assert Config.fetch(config, "repo..path") == :error
    assert_raise KeyError, fn -> Config.fetch!(config, "repo.missing") end
  end

  test "reports TOML decode errors with the configuration path" do
    project = temporary_project()
    write_config(project, "version = [\n")

    assert {:error, %Error{kind: :decode, path: path} = error} = Config.load(project)
    assert path == project.config_path
    assert error.message =~ "Cannot decode Hancho configuration"
    assert_raise Error, fn -> Config.load!(project) end
  end

  test "rejects unsupported versions and unknown keys" do
    project = temporary_project()
    write_config(project, "version = 2\nunknown = true\n")

    assert {:error, %Error{kind: :validation, details: errors} = error} = Config.load(project)
    assert error.message =~ "version"
    assert error.message =~ "unrecognized key: unknown"
    assert Enum.all?(errors, &match?(%Zoi.Error{}, &1))
  end

  test "reports file read errors" do
    project = temporary_project()
    File.mkdir_p!(project.config_path)

    assert {:error, %Error{kind: :read, path: path}} = Config.load(project)
    assert path == project.config_path
  end

  test "encodes a configuration that can be read again" do
    project = temporary_project()
    {:ok, config} = Config.default(project)

    assert {:ok, contents} = Config.encode(config)
    assert contents =~ "version = 1"
    assert contents =~ "[repo]"
    assert contents =~ "[logs]"
    assert {:ok, ^config} = Config.decode(contents, project)
  end

  defp temporary_project do
    root = Path.join(System.tmp_dir!(), "hancho-config-#{System.unique_integer([:positive])}")
    project = Project.new(root)
    File.mkdir_p!(project.hancho_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    project
  end

  defp write_config(project, contents), do: File.write!(project.config_path, contents)
end
