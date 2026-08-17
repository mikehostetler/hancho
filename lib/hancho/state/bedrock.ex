defmodule Hancho.State.Bedrock do
  @moduledoc "Manages the single repository-local Bedrock cluster used by Hancho."

  use GenServer

  alias Hancho.State.{Cluster, Repo}
  alias Bedrock.Cluster.Descriptor

  @ready_retry_limit 100
  @storage_window_in_ms 5_000

  @spec open(String.t()) :: :ok | {:error, term()}
  def open(path) do
    with {:ok, manager} <- manager() do
      GenServer.call(manager, {:open, Path.expand(path)}, :infinity)
    end
  end

  @spec transaction(String.t(), (-> term())) :: term()
  def transaction(path, function) when is_function(function, 0) do
    with {:ok, manager} <- manager() do
      GenServer.call(manager, {:transaction, Path.expand(path), function}, :infinity)
    end
  end

  @spec flush(String.t()) :: :ok | {:error, term()}
  def flush(path) do
    with {:ok, manager} <- manager() do
      GenServer.call(manager, {:flush, Path.expand(path)}, :infinity)
    end
  end

  @doc false
  @spec reset() :: :ok
  def reset do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      manager -> GenServer.call(manager, :reset, :infinity)
    end
  end

  @impl true
  def init(:ok) do
    Process.flag(:trap_exit, true)
    {:ok, %{path: nil, supervisor: nil}}
  end

  @impl true
  def handle_call({:open, path}, _from, %{path: path, supervisor: supervisor} = state)
      when is_pid(supervisor) do
    {:reply, :ok, state}
  end

  def handle_call({:open, path}, _from, state) do
    state = stop_cluster(state)

    case start_cluster(path) do
      {:ok, supervisor} -> {:reply, :ok, %{path: path, supervisor: supervisor}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:transaction, path, function},
        _from,
        %{path: path, supervisor: supervisor} = state
      )
      when is_pid(supervisor) do
    result = safely(fn -> Repo.transact(function, retry_limit: @ready_retry_limit) end)
    {:reply, result, state}
  end

  def handle_call({:transaction, _path, _function}, _from, state) do
    {:reply, {:error, :store_not_open}, state}
  end

  def handle_call({:flush, path}, _from, %{path: path, supervisor: supervisor} = state)
      when is_pid(supervisor) do
    Process.sleep(@storage_window_in_ms + 100)

    marker = "hancho/internal/durability-marker"
    value = Integer.to_string(System.system_time(:microsecond))

    result =
      with :ok <- safely(fn -> Repo.transact(fn -> Repo.put(marker, value) end) end) do
        case safely(fn -> Repo.transact(fn -> {:ok, Repo.get(marker)} end) end) do
          {:ok, ^value} -> :ok
          {:ok, other} -> {:error, {:durability_marker_mismatch, other}}
          {:error, _reason} = error -> error
        end
      end

    {:reply, result, state}
  end

  def handle_call({:flush, _path}, _from, state), do: {:reply, {:error, :store_not_open}, state}

  def handle_call(:reset, _from, state), do: {:reply, :ok, stop_cluster(state)}

  @impl true
  def handle_info({:EXIT, supervisor, _reason}, %{supervisor: supervisor} = state) do
    {:noreply, %{state | path: nil, supervisor: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp manager do
    case Process.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, :ok, name: __MODULE__) do
          {:ok, manager} -> {:ok, manager}
          {:error, {:already_started, manager}} -> {:ok, manager}
          {:error, reason} -> {:error, {:bedrock_manager, reason}}
        end

      manager ->
        {:ok, manager}
    end
  end

  defp start_cluster(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, _applications} <- Application.ensure_all_started(:bedrock),
         :ok <- ensure_distribution(path),
         :ok <- configure(path),
         :ok <- write_descriptor(path),
         {:ok, supervisor} <- Supervisor.start_link([{Cluster, []}], strategy: :one_for_one),
         :ok <- await_ready(supervisor) do
      {:ok, supervisor}
    else
      {:error, reason} -> {:error, {:bedrock_start, reason}}
    end
  end

  defp configure(path) do
    workers_path = Path.join(path, "workers")

    Application.put_env(:hancho, Cluster,
      capabilities: [:coordination, :log, :storage],
      trace: [],
      path_to_descriptor: Path.join(path, "bedrock.cluster"),
      coordinator: [path: Path.join(path, "coordinator")],
      storage: [path: workers_path],
      log: [path: workers_path]
    )

    :ok
  end

  defp ensure_distribution(path) do
    if Node.alive?() do
      :ok
    else
      suffix = :sha256 |> :crypto.hash(path) |> Base.encode16(case: :lower) |> binary_part(0, 12)
      node_name = String.to_atom("hancho_#{suffix}@127.0.0.1")

      case Node.start(node_name, :longnames) do
        {:ok, _pid} -> :ok
        {:error, reason} -> {:error, {:distribution, reason}}
      end
    end
  end

  defp write_descriptor(path) do
    path
    |> Path.join("bedrock.cluster")
    |> File.write(
      Descriptor.encode_cluster_file_contents(Descriptor.new(Cluster.name(), [Node.self()]))
    )
  end

  defp await_ready(supervisor) do
    case safely(fn -> Repo.transact(fn -> {:ok, :ready} end, retry_limit: @ready_retry_limit) end) do
      {:ok, :ready} ->
        :ok

      {:error, reason} ->
        Supervisor.stop(supervisor)
        {:error, {:not_ready, reason}}

      other ->
        Supervisor.stop(supervisor)
        {:error, {:not_ready, other}}
    end
  end

  defp stop_cluster(%{supervisor: supervisor} = state) when is_pid(supervisor) do
    if Process.alive?(supervisor), do: Supervisor.stop(supervisor)
    %{state | path: nil, supervisor: nil}
  end

  defp stop_cluster(state), do: %{state | path: nil, supervisor: nil}

  defp safely(function) do
    function.()
  rescue
    exception -> {:error, {:bedrock, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:bedrock, {kind, reason}}}
  end
end
