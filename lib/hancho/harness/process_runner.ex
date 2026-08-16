defmodule Hancho.Harness.ProcessRunner do
  @moduledoc false

  alias Hancho.{Error, OSProcess}

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

    with {:ok, stdout, stderr} <- open_logs(stdout_path, stderr_path) do
      try do
        executable = resolve_executable(command, cwd)

        case OSProcess.start(executable, args, cwd: cwd) do
          {:ok, process} ->
            await(%{
              process: process,
              started: System.monotonic_time(:millisecond),
              timeout_ms: timeout_ms,
              max_output_bytes: max_output_bytes,
              output_bytes: 0,
              stdout: stdout,
              stderr: stderr,
              stdout_path: stdout_path,
              stderr_path: stderr_path,
              cancel_ref: cancel_ref
            })

          {:error, reason} ->
            {:error, process_error(command, reason)}
        end
      after
        File.close(stdout)
        File.close(stderr)
      end
    else
      {:error, reason} -> {:error, process_error(command, reason)}
    end
  rescue
    error in ErlangError -> {:error, process_error(command, Exception.message(error))}
  end

  defp open_logs(stdout_path, stderr_path) do
    with {:ok, stdout} <- File.open(stdout_path, [:write, :binary]) do
      case File.open(stderr_path, [:write, :binary]) do
        {:ok, stderr} ->
          {:ok, stdout, stderr}

        {:error, reason} ->
          File.close(stdout)
          {:error, reason}
      end
    end
  end

  defp await(state) do
    elapsed = System.monotonic_time(:millisecond) - state.started

    if elapsed >= state.timeout_ms do
      stop(state.process)
      {:ok, process_result("timeout", nil, state)}
    else
      receive do
        {OSProcess, reference, :stdout, data}
        when reference == state.process.reference ->
          receive_output(:stdout, data, state)

        {OSProcess, reference, :stderr, data}
        when reference == state.process.reference ->
          receive_output(:stderr, data, state)

        {OSProcess, reference, :exit, status}
        when reference == state.process.reference ->
          result_status = if status == 0, do: "success", else: "failure"
          {:ok, process_result(result_status, status, state)}

        {:hancho_cancel, cancel_ref}
        when not is_nil(state.cancel_ref) and cancel_ref == state.cancel_ref ->
          stop(state.process)
          {:ok, process_result("cancelled", nil, state)}
      after
        @poll_ms -> await(state)
      end
    end
  end

  defp receive_output(stream, data, state) do
    device = Map.fetch!(state, stream)
    :ok = IO.binwrite(device, data)
    next = %{state | output_bytes: state.output_bytes + IO.iodata_length(data)}

    if next.output_bytes > next.max_output_bytes do
      stop(next.process)
      {:ok, process_result("output_limit", nil, next)}
    else
      await(next)
    end
  end

  defp stop(process) do
    _result = OSProcess.stop(process)
    :ok
  end

  defp process_result(status, exit_status, state) do
    %{
      status: status,
      exit_status: exit_status,
      stdout_path: state.stdout_path,
      stderr_path: state.stderr_path
    }
  end

  defp resolve_executable(command, cwd) do
    cond do
      Path.type(command) == :absolute -> command
      String.contains?(command, "/") -> Path.expand(command, cwd)
      executable = System.find_executable(command) -> executable
      true -> command
    end
  end

  defp process_error(command, reason) do
    %Error{
      code: :process_start_failed,
      exit_status: 69,
      message: "Cannot start '#{command}': #{inspect(reason)}"
    }
  end
end
