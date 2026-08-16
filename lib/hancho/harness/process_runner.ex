defmodule Hancho.Harness.ProcessRunner do
  @moduledoc false

  alias Hancho.Error

  @poll_ms 25

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(command, args, options) do
    stdout_path = Keyword.fetch!(options, :stdout_path)
    stderr_path = Keyword.fetch!(options, :stderr_path)
    timeout_ms = Keyword.get(options, :timeout_ms, 900_000)
    max_output_bytes = Keyword.get(options, :max_output_bytes, 10_485_760)
    cwd = Keyword.get(options, :cwd, File.cwd!())
    cancel_ref = Keyword.get(options, :cancel_ref)

    File.mkdir_p!(Path.dirname(stdout_path))
    File.mkdir_p!(Path.dirname(stderr_path))

    shell_script = ~s(out="$1"; err="$2"; shift 2; exec "$@" >"$out" 2>"$err")
    executable = resolve_executable(command, cwd)
    shell = System.find_executable("sh") || "/bin/sh"

    port =
      Port.open(
        {:spawn_executable, shell},
        [
          :binary,
          :exit_status,
          :hide,
          {:cd, cwd},
          {:args,
           ["-c", shell_script, "hancho-adapter", stdout_path, stderr_path, executable | args]}
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    started = System.monotonic_time(:millisecond)

    await(
      port,
      os_pid,
      started,
      timeout_ms,
      max_output_bytes,
      stdout_path,
      stderr_path,
      cancel_ref
    )
  rescue
    error in ErlangError ->
      {:error,
       %Error{
         code: :process_start_failed,
         exit_status: 69,
         message: "Cannot start '#{command}': #{Exception.message(error)}"
       }}
  end

  defp await(port, os_pid, started, timeout_ms, max_bytes, stdout, stderr, cancel_ref) do
    elapsed = System.monotonic_time(:millisecond) - started

    cond do
      elapsed >= timeout_ms ->
        terminate_tree(os_pid)
        close_port(port)
        {:ok, process_result("timeout", nil, stdout, stderr)}

      output_size(stdout) + output_size(stderr) > max_bytes ->
        terminate_tree(os_pid)
        close_port(port)
        {:ok, process_result("output_limit", nil, stdout, stderr)}

      true ->
        receive do
          {^port, {:exit_status, status}} ->
            result_status = if status == 0, do: "success", else: "failure"
            {:ok, process_result(result_status, status, stdout, stderr)}

          {:hancho_cancel, ^cancel_ref} when not is_nil(cancel_ref) ->
            terminate_tree(os_pid)
            close_port(port)
            {:ok, process_result("cancelled", nil, stdout, stderr)}

          {^port, {:data, _data}} ->
            await(port, os_pid, started, timeout_ms, max_bytes, stdout, stderr, cancel_ref)
        after
          @poll_ms ->
            await(port, os_pid, started, timeout_ms, max_bytes, stdout, stderr, cancel_ref)
        end
    end
  end

  defp process_result(status, exit_status, stdout, stderr) do
    %{status: status, exit_status: exit_status, stdout_path: stdout, stderr_path: stderr}
  end

  defp output_size(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.size
      {:error, _} -> 0
    end
  end

  defp resolve_executable(command, cwd) do
    cond do
      Path.type(command) == :absolute -> command
      String.contains?(command, "/") -> Path.expand(command, cwd)
      executable = System.find_executable(command) -> executable
      true -> command
    end
  end

  defp terminate_tree(pid) do
    descendants(pid)
    |> Enum.reverse()
    |> Enum.each(&signal(&1, "TERM"))

    signal(pid, "TERM")
    Process.sleep(100)

    descendants(pid)
    |> Enum.reverse()
    |> Enum.each(&signal(&1, "KILL"))

    signal(pid, "KILL")
  end

  defp descendants(pid) do
    children =
      case System.cmd("pgrep", ["-P", to_string(pid)], stderr_to_stdout: true) do
        {output, 0} -> output |> String.split("\n", trim: true) |> Enum.map(&String.to_integer/1)
        _ -> []
      end

    children ++ Enum.flat_map(children, &descendants/1)
  rescue
    _ -> []
  end

  defp signal(pid, signal) do
    System.cmd("kill", ["-#{signal}", to_string(pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    _ -> :ok
  end
end
