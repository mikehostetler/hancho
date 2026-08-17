defmodule Hancho.FactoryLease do
  @moduledoc "Owns the single mutating factory lease for one repository."

  @heartbeat_interval_ms 5_000
  @stale_after_ms 60_000
  @retry_limit 4

  @schema Zoi.struct(
            __MODULE__,
            %{
              path: Zoi.string() |> Zoi.min(1),
              owner_path: Zoi.string() |> Zoi.min(1),
              token: Zoi.string() |> Zoi.min(1),
              heartbeat_pid: Zoi.any(),
              stale_after_ms: Zoi.integer() |> Zoi.min(1)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attributes), do: Zoi.parse(@schema, attributes)

  @spec with_lease(Hancho.Project.t(), keyword(), (-> term())) :: term()
  def with_lease(project, options, function) when is_function(function, 0) do
    if Keyword.get(options, :factory_lease) == :held do
      function.()
    else
      with {:ok, lease} <- acquire(project, options) do
        result = safely(function)

        case release(lease) do
          :ok -> result
          {:error, reason} -> {:error, {:factory_lease_release_failed, reason, result}}
        end
      end
    end
  end

  @spec acquire(Hancho.Project.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(project, options \\ []) do
    stale_after_ms = Keyword.get(options, :lease_stale_after_ms, @stale_after_ms)
    command = Keyword.get(options, :lease_command, "hancho")
    path = Path.join(project.hancho_dir, "factory.lock")

    with :ok <- File.mkdir_p(project.hancho_dir) do
      acquire_path(path, command, stale_after_ms, @retry_limit)
    end
  end

  @spec release(t()) :: :ok | {:error, term()}
  def release(%__MODULE__{} = lease) do
    stop_heartbeat(lease.heartbeat_pid)

    case read_owner(lease.owner_path) do
      {:ok, %{"token" => token}} when token == lease.token ->
        with :ok <- remove_if_present(lease.owner_path),
             :ok <- remove_lock_directory(lease.path) do
          :ok
        end

      {:ok, _owner} ->
        {:error, :factory_lease_owner_changed}

      {:error, :enoent} ->
        remove_lock_directory(lease.path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp acquire_path(_path, _command, _stale_after_ms, 0),
    do: {:error, :factory_lease_contention}

  defp acquire_path(path, command, stale_after_ms, attempts) do
    case File.mkdir(path) do
      :ok ->
        create_owner(path, command, stale_after_ms)

      {:error, :eexist} ->
        with :ok <- reclaim_if_stale(path, stale_after_ms) do
          acquire_path(path, command, stale_after_ms, attempts - 1)
        end

      {:error, reason} ->
        {:error, {:factory_lease_create_failed, reason}}
    end
  end

  defp create_owner(path, command, stale_after_ms) do
    token = :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
    owner_path = Path.join(path, "owner.json")
    owner = owner(token, command)

    with :ok <- write_owner(owner_path, owner),
         heartbeat when is_pid(heartbeat) <-
           start_heartbeat(owner_path, owner, stale_after_ms),
         {:ok, lease} <-
           new(%{
             path: path,
             owner_path: owner_path,
             token: token,
             heartbeat_pid: heartbeat,
             stale_after_ms: stale_after_ms
           }) do
      {:ok, lease}
    else
      {:error, reason} ->
        _result = File.rm_rf(path)
        {:error, {:factory_lease_owner_failed, reason}}
    end
  end

  defp start_heartbeat(owner_path, owner, stale_after_ms) do
    parent = self()
    interval_ms = min(@heartbeat_interval_ms, max(div(stale_after_ms, 3), 1))

    spawn(fn ->
      monitor = Process.monitor(parent)
      heartbeat_loop(monitor, owner_path, owner, interval_ms)
    end)
  end

  defp heartbeat_loop(parent_monitor, owner_path, owner, interval_ms) do
    expected_token = owner["token"]

    receive do
      {:stop, from} ->
        send(from, {:heartbeat_stopped, self()})

      {:DOWN, ^parent_monitor, :process, _parent, _reason} ->
        :ok
    after
      interval_ms ->
        updated = Map.put(owner, "heartbeat_at_ms", now_ms())

        case owner_token(owner_path) do
          {:ok, ^expected_token} ->
            case write_owner(owner_path, updated) do
              :ok -> heartbeat_loop(parent_monitor, owner_path, updated, interval_ms)
              {:error, _reason} -> :ok
            end

          _other ->
            :ok
        end
    end
  end

  defp stop_heartbeat(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      Process.unlink(pid)
      send(pid, {:stop, self()})

      receive do
        {:heartbeat_stopped, ^pid} -> :ok
      after
        1_000 -> Process.exit(pid, :kill)
      end
    end

    :ok
  end

  defp reclaim_if_stale(path, stale_after_ms) do
    owner_path = Path.join(path, "owner.json")

    case read_owner(owner_path) do
      {:ok, owner} ->
        heartbeat_at = Map.get(owner, "heartbeat_at_ms", 0)

        if now_ms() - heartbeat_at > stale_after_ms do
          reclaim(path)
        else
          {:error, {:factory_busy, owner}}
        end

      {:error, :enoent} ->
        reclaim_missing_owner(path, stale_after_ms)

      {:error, reason} ->
        {:error, {:factory_lease_invalid, reason}}
    end
  end

  defp reclaim_missing_owner(path, stale_after_ms) do
    case File.stat(path, time: :posix) do
      {:ok, stat} ->
        if now_ms() - stat.mtime * 1_000 > stale_after_ms do
          reclaim(path)
        else
          {:error, {:factory_busy, %{path: path, owner: "initializing"}}}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:factory_lease_stat_failed, reason}}
    end
  end

  defp reclaim(path) do
    quarantine = path <> ".stale-" <> Integer.to_string(System.unique_integer([:positive]))

    case File.rename(path, quarantine) do
      :ok ->
        case File.rm_rf(quarantine) do
          {:ok, _paths} ->
            :ok

          {:error, reason, failed_path} ->
            {:error, {:factory_lease_reclaim_failed, failed_path, reason}}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, {:factory_lease_reclaim_failed, path, reason}}
    end
  end

  defp owner(token, command) do
    now = now_ms()

    %{
      "schema_version" => 1,
      "token" => token,
      "command" => command,
      "os_pid" => System.pid(),
      "host" => hostname(),
      "started_at_ms" => now,
      "heartbeat_at_ms" => now
    }
  end

  defp write_owner(path, owner) do
    temporary = path <> ".tmp-" <> owner["token"]

    with :ok <- File.write(temporary, Jason.encode!(owner), [:binary]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    end
  end

  defp read_owner(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, owner} when is_map(owner) <- Jason.decode(contents) do
      {:ok, owner}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_owner}
    end
  end

  defp owner_token(path) do
    with {:ok, owner} <- read_owner(path),
         token when is_binary(token) <- owner["token"] do
      {:ok, token}
    else
      _other -> {:error, :invalid_owner}
    end
  end

  defp remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_lock_directory(path) do
    case File.rmdir(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp safely(function) do
    function.()
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      {:error, _reason} -> "unknown"
    end
  end

  defp now_ms, do: System.system_time(:millisecond)
end
