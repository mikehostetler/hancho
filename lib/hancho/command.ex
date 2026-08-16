defmodule Hancho.Command do
  @moduledoc """
  Runs operating-system commands under erlexec process management.

  Each command gets its own process group. Hancho stops the complete group when
  a timeout occurs.
  """

  alias Hancho.Command.Result

  @default_timeout 30_000
  @shutdown_timeout 5_000

  @type option ::
          {:cwd, String.t()}
          | {:env, [{String.t(), String.t() | false}]}
          | {:input, iodata()}
          | {:stderr_to_stdout, boolean()}
          | {:timeout, pos_integer()}

  @spec run(String.t(), [String.t()], [option()]) :: {:ok, Result.t()} | {:error, term()}
  def run(executable, arguments, options \\ []) do
    timeout = Keyword.get(options, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout
    input = Keyword.get(options, :input)

    with :ok <- Hancho.Command.Runtime.ensure_started(),
         {:ok, _pid, os_pid} <- start(executable, arguments, input, options, deadline) do
      case send_input(os_pid, input) do
        :ok -> collect(os_pid, [], [], deadline)
        {:error, reason} -> stop_after_error(os_pid, reason)
      end
    end
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start(executable, arguments, input, options, deadline) do
    command = [executable | arguments]
    merge_stderr? = Keyword.get(options, :stderr_to_stdout, false)

    exec_options =
      [:monitor, :stdout, {:group, 0}, :kill_group]
      |> maybe_put({:stderr, :stdout}, merge_stderr?)
      |> maybe_put(:stderr, not merge_stderr?)
      |> maybe_put(:stdin, input != nil)
      |> maybe_put({:cd, options[:cwd]}, options[:cwd] != nil)
      |> maybe_put({:env, options[:env]}, options[:env] != nil)

    :exec.run(command, exec_options, remaining(deadline))
  end

  defp send_input(_os_pid, nil), do: :ok

  defp send_input(os_pid, input) do
    with :ok <- :exec.send(os_pid, IO.iodata_to_binary(input)) do
      :exec.send(os_pid, :eof)
    end
  end

  defp collect(os_pid, stdout, stderr, deadline) do
    receive do
      {:stdout, ^os_pid, data} ->
        collect(os_pid, [stdout, data], stderr, deadline)

      {:stderr, ^os_pid, data} ->
        collect(os_pid, stdout, [stderr, data], deadline)

      {:DOWN, ^os_pid, :process, _pid, :normal} ->
        result(stdout, stderr, 0)

      {:DOWN, ^os_pid, :process, _pid, {:exit_status, status}} ->
        finish(stdout, stderr, status)

      {:DOWN, ^os_pid, :process, _pid, reason} ->
        {:error, reason}
    after
      remaining(deadline) -> stop(os_pid)
    end
  end

  defp finish(stdout, stderr, status) do
    case :exec.status(status) do
      {:status, exit_status} -> result(stdout, stderr, exit_status)
      {:signal, signal, _core_dumped} -> {:error, {:signal, signal}}
    end
  end

  defp result(stdout, stderr, exit_status) do
    {:ok,
     %Result{
       stdout: IO.iodata_to_binary(stdout),
       stderr: IO.iodata_to_binary(stderr),
       exit_status: exit_status
     }}
  end

  defp stop(os_pid) do
    _result = :exec.stop(os_pid)
    await_stop(os_pid, System.monotonic_time(:millisecond) + @shutdown_timeout)
  end

  defp stop_after_error(os_pid, reason) do
    _result = :exec.stop(os_pid)
    _result = await_stop(os_pid, System.monotonic_time(:millisecond) + @shutdown_timeout)
    {:error, reason}
  end

  defp await_stop(os_pid, deadline) do
    receive do
      {:DOWN, ^os_pid, :process, _pid, _reason} ->
        {:error, :timeout}

      {:stdout, ^os_pid, _data} ->
        await_stop(os_pid, deadline)

      {:stderr, ^os_pid, _data} ->
        await_stop(os_pid, deadline)
    after
      remaining(deadline) -> {:error, {:timeout, :shutdown_failed}}
    end
  end

  defp remaining(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp maybe_put(options, option, true), do: [option | options]
  defp maybe_put(options, _option, false), do: options
end
