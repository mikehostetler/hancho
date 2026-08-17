defmodule Hancho.CommandTest do
  use ExUnit.Case, async: false

  alias Hancho.Command
  alias Hancho.Command.Result

  test "captures separate standard output and standard error" do
    assert {:ok, %Result{} = result} =
             Command.run("/bin/sh", ["-c", "printf output; printf error >&2; exit 7"])

    assert result.stdout == "output"
    assert result.stderr == "error"
    assert result.exit_status == 7
  end

  test "can merge standard error into standard output" do
    assert {:ok, %Result{stdout: "failure", stderr: "", exit_status: 3}} =
             Command.run("/bin/sh", ["-c", "printf failure >&2; exit 3"], stderr_to_stdout: true)
  end

  test "sends input and closes standard input" do
    assert {:ok, %Result{stdout: "hello", exit_status: 0}} =
             Command.run("/bin/cat", [], input: "hello")
  end

  test "stops the process when its output callback fails" do
    callback = fn :stdout, _data -> {:error, :disk_full} end

    assert Command.run(
             "/bin/sh",
             ["-c", "printf output; sleep 30"],
             on_output: callback
           ) == {:error, {:output_callback_failed, :disk_full}}
  end

  test "contains exceptions from its output callback" do
    callback = fn :stdout, _data -> raise "writer stopped" end

    assert {:error, {:output_callback_failed, {:exception, %RuntimeError{}}}} =
             Command.run("/bin/sh", ["-c", "printf output; sleep 30"], on_output: callback)
  end

  test "stops the process and its child process on timeout" do
    directory = temporary_directory()
    shell_pid_path = Path.join(directory, "shell.pid")
    child_pid_path = Path.join(directory, "child.pid")

    script = "echo $$ > '#{shell_pid_path}'; sleep 30 & echo $! > '#{child_pid_path}'; wait"

    assert Command.run("/bin/sh", ["-c", script], timeout: 200) == {:error, :timeout}

    shell_pid = shell_pid_path |> File.read!() |> String.trim()
    child_pid = child_pid_path |> File.read!() |> String.trim()

    refute eventually_alive?(shell_pid)
    refute eventually_alive?(child_pid)
  end

  defp eventually_alive?(pid, attempts \\ 20)

  defp eventually_alive?(pid, 0), do: alive?(pid)

  defp eventually_alive?(pid, attempts) do
    if alive?(pid) do
      Process.sleep(25)
      eventually_alive?(pid, attempts - 1)
    else
      false
    end
  end

  defp alive?(pid) do
    case System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-command-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
