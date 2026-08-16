defmodule HanchoTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule Harness do
    def version, do: "2.0.0"
    def providers, do: [%{provider: :codex}, %{provider: :pi}]
    def status(:codex), do: {:ok, %{smoke_ready: true}}
    def status(:pi), do: {:ok, %{smoke_ready: false}}
  end

  test "the CLI prints only its version" do
    assert capture_io(fn -> Hancho.CLI.main([]) end) == "0.1.0\n"
  end

  test "doctor reports repository and Beadwork state" do
    command = fn
      "/usr/bin/git", ["rev-parse", "--show-toplevel"], _options -> {"/repo\n", 0}
      "/usr/bin/git", ["branch", "--show-current"], _options -> {"main\n", 0}
      "/usr/bin/git", ["status", "--porcelain"], _options -> {"", 0}
      "/usr/local/bin/bw", ["--version"], _options -> {"bw 0.13.2\n", 0}
      "/usr/local/bin/bw", ["config", "list"], _options -> {"prefix=hancho\nversion=2\n", 0}
    end

    find_executable = fn
      "git" -> "/usr/bin/git"
      "bw" -> "/usr/local/bin/bw"
    end

    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 ["doctor"],
                 cwd: "/repo",
                 command: command,
                 find_executable: find_executable,
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
    command = fn
      "/usr/bin/git", ["rev-parse", "--show-toplevel"], _options -> {"/repo\n", 0}
      "/usr/bin/git", ["branch", "--show-current"], _options -> {"main\n", 0}
      "/usr/bin/git", ["status", "--porcelain"], _options -> {"", 0}
    end

    find_executable = fn
      "git" -> "/usr/bin/git"
      "bw" -> nil
    end

    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 ["doctor"],
                 cwd: "/repo",
                 command: command,
                 find_executable: find_executable,
                 harness: Harness,
                 start_harness: fn -> :ok end
               ) == 1
      end)

    assert output =~ "FAIL beadwork: Executable not found in PATH."
  end
end
