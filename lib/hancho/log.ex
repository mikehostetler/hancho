defmodule Hancho.Log do
  @moduledoc """
  Captures normalized factory activity in a repository-local log.

  One writer process serializes activity and sends it through an OTP Logger file
  handler. This keeps event order stable and permits synchronous disk writes.
  """

  use GenServer

  require Logger

  alias Hancho.Config
  alias Hancho.Config.Logs
  alias Hancho.Log.Event
  alias Hancho.Project

  @file_handler :hancho_factory_file
  @console_filter :hancho_factory_console_filter
  @queue_limit 1_000

  @type handle :: pid() | :disabled
  @type write_option ::
          {:event, String.t()} | {:level, Logger.level()} | {:metadata, map() | keyword()}

  @spec open(Project.t(), Config.t(), keyword()) :: {:ok, handle()} | {:error, term()}
  def open(project, config, options \\ [])

  def open(%Project{} = _project, %Config{logs: %Logs{enabled: false}}, _options),
    do: {:ok, :disabled}

  def open(%Project{} = project, %Config{} = config, options) do
    GenServer.start_link(__MODULE__, {project, config.logs, options})
  end

  @spec write(handle(), iodata(), [write_option()]) :: :ok | {:error, term()}
  def write(handle, message, options \\ [])

  def write(:disabled, _message, _options), do: :ok

  def write(pid, message, options) when is_pid(pid) do
    GenServer.call(pid, {:write, message, options}, :infinity)
  end

  @spec sync(handle()) :: :ok | {:error, term()}
  def sync(:disabled), do: :ok
  def sync(pid) when is_pid(pid), do: GenServer.call(pid, :sync, :infinity)

  @spec path(handle()) :: String.t() | nil
  def path(:disabled), do: nil
  def path(pid) when is_pid(pid), do: GenServer.call(pid, :path)

  @spec close(handle()) :: :ok
  def close(:disabled), do: :ok
  def close(pid) when is_pid(pid), do: GenServer.stop(pid, :normal, :infinity)

  @spec internal(Logger.level(), iodata(), keyword()) :: :ok
  def internal(level, message, metadata \\ []) do
    Logger.log(level, message, Keyword.put(metadata, :domain, [:hancho]))
  end

  @impl true
  def init({project, logs, options}) do
    with {:ok, base_metadata} <- normalize_metadata(Keyword.get(options, :metadata, %{})),
         {:ok, path} <- Project.log_path(project, logs.path),
         :ok <- prepare_file(project, path),
         :ok <- install_handlers(path, logs) do
      {:ok,
       %{
         path: path,
         logs: logs,
         sequence: 0,
         base_metadata: base_metadata,
         console_filter?: not logs.console
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:write, message, options}, _from, state) do
    metadata = Keyword.get(options, :metadata, %{})

    with {:ok, metadata} <- normalize_metadata(metadata),
         {:ok, event} <-
           Event.new(message,
             sequence: state.sequence + 1,
             level: Keyword.get(options, :level, :info),
             event: Keyword.get(options, :event, "activity.output"),
             metadata: Map.merge(state.base_metadata, metadata)
           ) do
      :ok =
        Logger.log(event.level, event.message,
          domain: [:hancho, :factory],
          hancho_event: Event.to_map(event)
        )

      result = maybe_sync(state.logs.sync_interval_ms)
      {:reply, result, %{state | sequence: event.sequence}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:sync, _from, state), do: {:reply, file_sync(), state}
  def handle_call(:path, _from, state), do: {:reply, state.path, state}

  @impl true
  def terminate(_reason, state) do
    _result = file_sync()
    _result = :logger.remove_handler(@file_handler)

    if state.console_filter? do
      _result = :logger.remove_handler_filter(:default, @console_filter)
    end

    :ok
  end

  defp prepare_file(project, path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(project.logs_path, 0o700),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- ensure_file(path),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp ensure_file(path) do
    case File.open(path, [:append, :binary], fn _file -> :ok end) do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp add_file_handler(path, logs) do
    formatter = {Hancho.Log.Formatter, %{format: logs.format}}

    config = %{
      level: :all,
      filter_default: :stop,
      filters: [hancho_factory: {&Hancho.Log.Filter.select/2, logs.include_internal}],
      formatter: formatter,
      config: %{
        type: :file,
        file: String.to_charlist(path),
        filesync_repeat_interval: sync_interval(logs.sync_interval_ms),
        max_no_bytes: logs.max_bytes,
        max_no_files: logs.max_files,
        compress_on_rotate: logs.compress,
        sync_mode_qlen: 0,
        drop_mode_qlen: @queue_limit,
        flush_qlen: @queue_limit,
        burst_limit_enable: false,
        overload_kill_enable: false
      }
    }

    :logger.add_handler(@file_handler, :logger_std_h, config)
  end

  defp install_handlers(path, logs) do
    with :ok <- add_file_handler(path, logs) do
      case configure_console(logs) do
        :ok ->
          :ok

        {:error, reason} ->
          _result = :logger.remove_handler(@file_handler)
          {:error, reason}
      end
    end
  end

  defp configure_console(%Logs{console: true}), do: :ok

  defp configure_console(%Logs{console: false, include_internal: include_internal?}) do
    case :logger.add_handler_filter(
           :default,
           @console_filter,
           {&Hancho.Log.Filter.suppress_selected/2, include_internal?}
         ) do
      :ok -> :ok
      {:error, {:not_found, :default}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_sync(0), do: file_sync()
  defp maybe_sync(_interval), do: :ok

  defp file_sync do
    case :logger_std_h.filesync(@file_handler) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_interval(0), do: :no_repeat
  defp sync_interval(interval), do: interval

  defp normalize_metadata(metadata) when is_list(metadata) do
    if Keyword.keyword?(metadata) do
      {:ok, metadata |> Map.new() |> Event.normalize()}
    else
      {:error, {:invalid_metadata, metadata}}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, Event.normalize(metadata)}
  defp normalize_metadata(metadata), do: {:error, {:invalid_metadata, metadata}}
end
