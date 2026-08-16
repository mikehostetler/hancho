defmodule Hancho.Git.Runner do
  @moduledoc false

  @behaviour Git.Runner

  @shutdown_timeout 5_000

  @impl true
  def run(binary, arguments, options) do
    {timeout, options} = Keyword.pop!(options, :timeout)
    {input, options} = Keyword.pop(options, :input)

    with :ok <- Hancho.ProcessManager.ensure_started(),
         {:ok, _pid, os_pid} <- start(binary, arguments, input, options) do
      case send_input(os_pid, input) do
        :ok -> collect(os_pid, [], timeout)
        {:error, reason} -> stop_after_error(os_pid, reason)
      end
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp start(binary, arguments, input, options) do
    command = [binary | arguments]

    exec_options =
      [:monitor, :stdout, {:stderr, :stdout}, {:group, 0}, :kill_group]
      |> maybe_put(:stdin, input != nil)
      |> maybe_put({:cd, options[:cd]}, options[:cd] != nil)
      |> maybe_put({:env, options[:env]}, options[:env] != nil)

    :exec.run(command, exec_options)
  end

  defp send_input(_os_pid, nil), do: :ok

  defp send_input(os_pid, input) do
    with :ok <- :exec.send(os_pid, IO.iodata_to_binary(input)) do
      :exec.send(os_pid, :eof)
    end
  end

  defp collect(os_pid, output, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    collect_until(os_pid, output, deadline)
  end

  defp collect_until(os_pid, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:stdout, ^os_pid, data} ->
        collect_until(os_pid, [output, data], deadline)

      {:DOWN, ^os_pid, :process, _pid, :normal} ->
        {:ok, {IO.iodata_to_binary(output), 0}}

      {:DOWN, ^os_pid, :process, _pid, {:exit_status, status}} ->
        finish(output, status)

      {:DOWN, ^os_pid, :process, _pid, reason} ->
        {:error, reason}
    after
      remaining -> stop(os_pid)
    end
  end

  defp finish(output, status) do
    case :exec.status(status) do
      {:status, exit_code} -> {:ok, {IO.iodata_to_binary(output), exit_code}}
      {:signal, signal, _core_dumped} -> {:error, {:signal, signal}}
    end
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
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ^os_pid, :process, _pid, _reason} ->
        {:error, :timeout}

      {:stdout, ^os_pid, _data} ->
        await_stop(os_pid, deadline)
    after
      remaining -> {:error, {:timeout, :shutdown_failed}}
    end
  end

  defp maybe_put(options, option, true), do: [option | options]
  defp maybe_put(options, _option, false), do: options
end
