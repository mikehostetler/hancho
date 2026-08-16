defmodule Hancho.OSProcess.Worker do
  @moduledoc false

  use GenServer

  def child_spec(options) do
    %{
      id: {__MODULE__, Keyword.fetch!(options, :reference)},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    owner = Keyword.fetch!(options, :owner)
    reference = Keyword.fetch!(options, :reference)
    command = Keyword.fetch!(options, :command)
    arguments = Keyword.fetch!(options, :arguments)

    command_options = options |> Keyword.fetch!(:options) |> command_options()

    case :exec.run_link([command | arguments], command_options) do
      {:ok, exec_pid, os_pid} ->
        {:ok,
         %{
           owner: owner,
           owner_monitor: Process.monitor(owner),
           reference: reference,
           exec_pid: exec_pid,
           os_pid: os_pid
         }}

      {:error, reason} ->
        {:stop, {:cannot_start_os_process, reason}}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    result = safe_stop(state.exec_pid)
    {:reply, result, state}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    send_event(state, :stdout, data)
    {:noreply, state}
  end

  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state) do
    send_event(state, :stderr, data)
    {:noreply, state}
  end

  def handle_info({:EXIT, exec_pid, reason}, %{exec_pid: exec_pid} = state) do
    send_event(state, :exit, exit_status(reason))
    {:stop, :normal, %{state | exec_pid: nil}}
  end

  def handle_info({:DOWN, monitor, :process, owner, _reason}, state)
      when monitor == state.owner_monitor and owner == state.owner do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{exec_pid: exec_pid}) when is_pid(exec_pid) do
    safe_stop(exec_pid)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp command_options(options) do
    [
      {:stdout, self()},
      {:stderr, self()},
      {:group, 0},
      :kill_group,
      {:kill_timeout, 1}
    ]
    |> add_stdin(Keyword.get(options, :stdin, :close))
    |> add_cwd(Keyword.get(options, :cwd))
    |> add_env(Keyword.get(options, :env, %{}))
  end

  defp add_stdin(options, :pipe), do: [:stdin | options]
  defp add_stdin(options, :close), do: [{:stdin, :close} | options]

  defp add_cwd(options, nil), do: options
  defp add_cwd(options, cwd), do: [{:cd, cwd} | options]

  defp add_env(options, env) when map_size(env) == 0, do: options
  defp add_env(options, env), do: [{:env, Map.to_list(env)} | options]

  defp safe_stop(exec_pid) do
    :exec.stop(exec_pid)
  catch
    :exit, _reason -> :ok
  end

  defp send_event(state, stream, data) do
    send(state.owner, {Hancho.OSProcess, state.reference, stream, data})
  end

  defp exit_status(:normal), do: 0

  defp exit_status({:exit_status, status}) do
    case :exec.status(status) do
      {:status, code} -> code
      {:signal, signal, _core_dump} -> 128 + :exec.signal_to_int(signal)
    end
  end

  defp exit_status(_reason), do: 1
end
