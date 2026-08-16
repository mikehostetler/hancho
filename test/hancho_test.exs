defmodule HanchoTest do
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

  test "the CLI has explicit help and version commands" do
    assert capture_io(fn -> assert Hancho.CLI.run([]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["--help"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["--version"]) == 0 end) == "0.1.0\n"
  end

  test "the CLI rejects an unknown command" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: unknown\nRun 'hancho --help' for usage.\n"
  end

  test "doctor reports repository and Beadwork state" do
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
    assert output =~ "PASS beadwork_version: bw 0.13.2"
    assert output =~ "PASS beadwork_repository: prefix=hancho, version=2"
    assert output =~ "PASS jido_harness: version 2.0.0"
    assert output =~ "PASS cli_agents: Ready: codex"
  end

  test "doctor fails when Beadwork is not installed" do
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
end
