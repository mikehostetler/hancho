defmodule Hancho.OSProcess do
  @moduledoc false

  alias Hancho.OSProcess.Worker

  @stop_timeout_ms 1_800

  @enforce_keys [:pid, :reference]
  defstruct [:pid, :reference]

  @type t :: %__MODULE__{pid: pid(), reference: reference()}

  @spec start(String.t(), [String.t()], keyword()) :: {:ok, t()} | {:error, term()}
  def start(command, arguments, options \\ []) do
    reference = make_ref()

    worker_options = [
      owner: self(),
      reference: reference,
      command: command,
      arguments: arguments,
      options: options
    ]

    case DynamicSupervisor.start_child(Hancho.OSProcess.Supervisor, {Worker, worker_options}) do
      {:ok, pid} -> {:ok, %__MODULE__{pid: pid, reference: reference}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec stop(t()) :: :ok | {:error, term()}
  def stop(%__MODULE__{pid: pid} = process) do
    monitor = Process.monitor(pid)
    result = safe_call(pid, :stop, 1_000)
    await_stop(pid, monitor)
    drain_events(process)
    result
  end

  defp await_stop(pid, monitor) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      @stop_timeout_ms ->
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
        after
          100 -> :ok
        end
    end
  end

  defp drain_events(process) do
    receive do
      {__MODULE__, reference, _stream, _data} when reference == process.reference ->
        drain_events(process)
    after
      0 -> :ok
    end
  end

  defp safe_call(pid, request, timeout) do
    GenServer.call(pid, request, timeout)
  catch
    :exit, _reason -> {:error, :closed}
  end
end
