defmodule Hancho.DoctorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule Harness do
    def version, do: "2.0.0"
    def providers, do: [%{provider: :codex}, %{provider: :pi}]
    def status(:codex), do: {:ok, %{smoke_ready: true}}
    def status(:pi), do: {:ok, %{smoke_ready: false}}
  end

  defmodule ProjectAPI do
    def discover(_options), do: {:ok, Hancho.Project.new("/repo")}
  end

  defmodule GitAPI do
    def executable, do: {:ok, "/usr/bin/git"}
    def status(_options), do: {:ok, %Git.Status{branch: "main", entries: []}}
  end

  defmodule BeadworkAPI do
    def executable, do: {:ok, "/usr/local/bin/bw"}
    def version(_options), do: {:ok, "bw 0.13.2"}
    def repository_config(_options), do: {:ok, "prefix=hancho\nversion=2"}
  end

  defmodule MissingBeadworkAPI do
    def executable, do: {:error, :not_found}
  end

  defmodule InvalidConfigAPI do
    def load(project) do
      {:error,
       %Hancho.Config.Error{
         kind: :validation,
         path: project.config_path,
         message: "Invalid test configuration",
         details: []
       }}
    end
  end

  test "reports repository and Beadwork state" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 ["doctor"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 git: GitAPI,
                 beadwork: BeadworkAPI,
                 harness: Harness,
                 start_harness: fn -> :ok end
               ) == 0
      end)

    assert output =~ "PASS repository: /repo"
    assert output =~ "PASS config: version 1, repo /repo"
    assert output =~ "PASS beadwork_version: bw 0.13.2"
    assert output =~ "PASS beadwork_repository: prefix=hancho, version=2"
    assert output =~ "PASS jido_harness: version 2.0.0"
    assert output =~ "PASS cli_agents: Ready: codex"
  end

  test "fails when Beadwork is not installed" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 ["doctor"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 git: GitAPI,
                 beadwork: MissingBeadworkAPI,
                 harness: Harness,
                 start_harness: fn -> :ok end
               ) == 1
      end)

    assert output =~ "FAIL beadwork: Executable not found in PATH."
  end

  test "fails when the repository configuration is invalid" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 ["doctor"],
                 project_api: ProjectAPI,
                 git: GitAPI,
                 beadwork: BeadworkAPI,
                 config_api: InvalidConfigAPI,
                 harness: Harness,
                 start_harness: fn -> :ok end
               ) == 1
      end)

    assert output =~ "FAIL config: Invalid test configuration"
  end
end
