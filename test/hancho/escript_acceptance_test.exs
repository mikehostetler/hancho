defmodule Hancho.EscriptAcceptanceTest do
  use Hancho.RepositoryCase, async: false

  setup_all do
    source_root = Path.expand("../..", __DIR__)

    {output, status} =
      System.cmd(Path.join(source_root, "scripts/build-release.sh"), [],
        cd: source_root,
        stderr_to_stdout: true
      )

    assert status == 0, output
    binary = Path.join(source_root, "hancho")
    assert File.exists?(binary)
    %{source_root: source_root, binary: binary}
  end

  test "runs after it moves outside the source tree and creates durable SQLite state", context do
    destination_root = temporary_directory!("moved-escript")
    moved = Path.join(destination_root, "hancho")
    File.cp!(context.binary, moved)
    File.chmod!(moved, 0o700)

    assert {version, 0} = System.cmd(moved, ["version"])
    assert version =~ "0.1.0"
    assert {help, 0} = System.cmd(moved, ["--help"])
    assert help =~ "Hancho coordinates"

    repository_root = temporary_git_repository!("moved-run")

    assert {_output, 0} =
             System.cmd(moved, ["init", "--repo", repository_root], stderr_to_stdout: true)

    assert {_output, 0} =
             System.cmd(moved, ["doctor", "--repo", repository_root], stderr_to_stdout: true)

    assert {_output, 0} =
             System.cmd(moved, ["run", "walking_skeleton", "moved", "--repo", repository_root],
               stderr_to_stdout: true
             )

    assert File.exists?(Path.join(repository_root, ".hancho/hancho.sqlite3"))
  end

  test "uses the same controller in tmux and prevents a duplicate detached start", context do
    repository_root = temporary_git_repository!("tmux")

    assert {_output, 0} =
             System.cmd(context.binary, ["init", "--repo", repository_root],
               stderr_to_stdout: true
             )

    env = [{"HANCHO_EXECUTABLE", context.binary}]

    assert {first_output, 0} =
             System.cmd(context.binary, ["up", "--tmux", "--repo", repository_root, "--json"],
               env: env,
               stderr_to_stdout: true
             )

    first = Hancho.JSON.decode!(first_output)
    assert first["health"] == "healthy"
    assert is_binary(first["session"])

    assert {second_output, 0} =
             System.cmd(context.binary, ["up", "-d", "--repo", repository_root, "--json"],
               env: env,
               stderr_to_stdout: true
             )

    second = Hancho.JSON.decode!(second_output)
    assert second["factory_id"] == first["factory_id"]
    assert second["session"] == first["session"]

    assert {_output, 0} =
             System.cmd(context.binary, ["down", "--repo", repository_root],
               stderr_to_stdout: true
             )

    assert_eventually(fn ->
      case System.cmd("tmux", ["has-session", "-t", first["session"]], stderr_to_stdout: true) do
        {_output, 0} -> false
        _ -> true
      end
    end)
  end

  test "handles an operating-process TERM as a safe first interrupt", context do
    repository_root = temporary_git_repository!("signal")

    assert {_output, 0} =
             System.cmd(context.binary, ["init", "--repo", repository_root],
               stderr_to_stdout: true
             )

    port =
      Port.open({:spawn_executable, context.binary}, [
        :binary,
        :exit_status,
        :hide,
        {:args, ["up", "--repo", repository_root]}
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    assert_eventually(fn -> File.exists?(Path.join(repository_root, ".hancho/factory.json")) end)

    {_output, 0} =
      System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)

    assert await_exit(port, 8_000) == 0

    metadata =
      Path.join(repository_root, ".hancho/factory.json") |> File.read!() |> Hancho.JSON.decode!()

    assert metadata["state"] == "stopped"
    assert metadata["health"] == "stopped"
  end

  test "installs, upgrades, rolls back, and opens compatible local state", context do
    install_root = temporary_directory!("install-rollback")
    installed = Path.join(install_root, "hancho")
    File.cp!(context.binary, installed)
    File.chmod!(installed, 0o755)

    assert {_output, 0} =
             System.cmd(
               Path.join(context.source_root, "scripts/install-hancho.sh"),
               [context.binary, installed],
               stderr_to_stdout: true
             )

    repository_root = temporary_git_repository!("rollback-state")
    assert {_output, 0} = System.cmd(installed, ["init", "--repo", repository_root])

    assert {_output, 0} =
             System.cmd(Path.join(context.source_root, "scripts/rollback-hancho.sh"), [installed],
               stderr_to_stdout: true
             )

    assert {version, 0} = System.cmd(installed, ["version"])
    assert version =~ "0.1.0"

    assert {_output, 0} =
             System.cmd(installed, ["doctor", "--repo", repository_root], stderr_to_stdout: true)
  end

  defp await_exit(port, timeout) do
    started = System.monotonic_time(:millisecond)
    receive_exit(port, started, timeout)
  end

  defp receive_exit(port, started, timeout) do
    remaining = max(timeout - (System.monotonic_time(:millisecond) - started), 0)

    receive do
      {^port, {:exit_status, status}} -> status
      {^port, {:data, _data}} -> receive_exit(port, started, timeout)
    after
      remaining -> flunk("Escript did not exit after TERM.")
    end
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(_fun, 0), do: flunk("Condition did not become true.")

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: assert(true),
      else:
        (
          Process.sleep(50)
          assert_eventually(fun, attempts - 1)
        )
  end
end
