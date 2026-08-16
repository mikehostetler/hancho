defmodule Hancho.Harness.ProcessRunnerTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.ProcessRunner

  test "captures standard output and standard error separately" do
    root = temporary_directory!()
    script = executable!(root, "separate", "#!/bin/sh\nprintf 'out'\nprintf 'err' >&2\n")

    assert {:ok, result} =
             ProcessRunner.run(script, [],
               stdout_path: Path.join(root, "out.log"),
               stderr_path: Path.join(root, "err.log")
             )

    assert result.status == "success"
    assert File.read!(result.stdout_path) == "out"
    assert File.read!(result.stderr_path) == "err"
  end

  test "enforces timeout and output limits" do
    root = temporary_directory!()
    slow = executable!(root, "slow", "#!/bin/sh\nsleep 2\n")

    assert {:ok, %{status: "timeout"}} =
             ProcessRunner.run(slow, [],
               stdout_path: Path.join(root, "slow.out"),
               stderr_path: Path.join(root, "slow.err"),
               timeout_ms: 50
             )

    noisy = executable!(root, "noisy", "#!/bin/sh\nwhile :; do printf '0123456789'; done\n")

    assert {:ok, %{status: "output_limit"}} =
             ProcessRunner.run(noisy, [],
               stdout_path: Path.join(root, "noisy.out"),
               stderr_path: Path.join(root, "noisy.err"),
               max_output_bytes: 100,
               timeout_ms: 2_000
             )
  end

  test "cancels an adapter and its child process" do
    root = temporary_directory!()
    child_file = Path.join(root, "child.pid")

    script =
      executable!(
        root,
        "children",
        "#!/bin/sh\nprintf 'available-before-cancel'\nsleep 30 &\nchild=$!\nprintf '%s' \"$child\" > \"$1\"\nwait \"$child\"\n"
      )

    cancel_ref = make_ref()

    task =
      Task.async(fn ->
        ProcessRunner.run(script, [child_file],
          stdout_path: Path.join(root, "child.out"),
          stderr_path: Path.join(root, "child.err"),
          cancel_ref: cancel_ref,
          timeout_ms: 5_000
        )
      end)

    wait_for_file(child_file)
    send(task.pid, {:hancho_cancel, cancel_ref})
    assert {:ok, %{status: "cancelled"}} = Task.await(task, 2_000)
    assert File.read!(Path.join(root, "child.out")) == "available-before-cancel"

    child_pid = File.read!(child_file)
    {_output, status} = System.cmd("kill", ["-0", child_pid], stderr_to_stdout: true)
    assert status != 0
  end

  defp executable!(root, name, content) do
    path = Path.join(root, name)
    File.write!(path, content)
    File.chmod!(path, 0o700)
    path
  end

  defp wait_for_file(path, attempts \\ 50)
  defp wait_for_file(_path, 0), do: flunk("child pid file was not created")

  defp wait_for_file(path, attempts) do
    if File.exists?(path) do
      :ok
    else
      Process.sleep(10)
      wait_for_file(path, attempts - 1)
    end
  end
end
