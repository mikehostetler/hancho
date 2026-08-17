defmodule Hancho.Config do
  @moduledoc """
  Reads and validates repository-local Hancho configuration.

  Use dot-delimited keys to read values:

      {:ok, config} = Hancho.Config.load(project)
      Hancho.Config.get(config, "repo.path")
  """

  alias Hancho.Config.Error
  alias Hancho.Config.Logs
  alias Hancho.Config.Repo
  alias Hancho.Project

  @current_version 1

  @enforce_keys [:version, :repo, :logs]
  defstruct [:version, :repo, :logs]

  @type t :: %__MODULE__{version: pos_integer(), repo: Repo.t(), logs: Logs.t()}
  @type key :: String.t()

  @spec current_version() :: pos_integer()
  def current_version, do: @current_version

  @spec load(Project.t() | keyword()) :: {:ok, t()} | {:error, Error.t() | term()}
  def load(project_or_options \\ [])

  def load(%Project{} = project) do
    case File.read(project.config_path) do
      {:ok, contents} -> decode(contents, project)
      {:error, :enoent} -> default(project)
      {:error, reason} -> {:error, read_error(project.config_path, reason)}
    end
  end

  def load(options) when is_list(options) do
    project_api = Keyword.get(options, :project_api, Project)

    with {:ok, project} <- project_api.discover(options) do
      load(project)
    end
  end

  @spec load!(Project.t() | keyword()) :: t()
  def load!(project_or_options \\ []) do
    case load(project_or_options) do
      {:ok, config} ->
        config

      {:error, %Error{} = error} ->
        raise error

      {:error, reason} ->
        raise ArgumentError, "cannot load Hancho configuration: #{inspect(reason)}"
    end
  end

  @spec default(Project.t()) :: {:ok, t()} | {:error, Error.t()}
  def default(%Project{} = project), do: validate(%{}, project)

  @spec decode(String.t(), Project.t()) :: {:ok, t()} | {:error, Error.t()}
  def decode(contents, %Project{} = project) when is_binary(contents) do
    case TomlElixir.decode(contents) do
      {:ok, values} -> validate(values, project)
      {:error, reason} -> {:error, decode_error(project.config_path, reason)}
    end
  end

  @spec validate(map(), Project.t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(values, %Project{} = project) when is_map(values) do
    case Zoi.parse(schema(project), values) do
      {:ok, values} -> {:ok, build(values, project)}
      {:error, errors} -> {:error, validation_error(project.config_path, errors)}
    end
  end

  @spec encode(t()) :: {:ok, String.t()} | {:error, term()}
  def encode(%__MODULE__{} = config), do: config |> to_map() |> TomlElixir.encode()

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = config) do
    %{
      "version" => config.version,
      "repo" => %{"path" => config.repo.path},
      "logs" => %{
        "enabled" => config.logs.enabled,
        "path" => config.logs.path,
        "format" => Atom.to_string(config.logs.format),
        "console" => config.logs.console,
        "include_internal" => config.logs.include_internal,
        "sync_interval_ms" => config.logs.sync_interval_ms,
        "max_bytes" => config.logs.max_bytes,
        "max_files" => config.logs.max_files,
        "compress" => config.logs.compress
      }
    }
  end

  @spec fetch(t(), key()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{} = config, key) when is_binary(key) do
    segments = String.split(key, ".", trim: false)

    if Enum.any?(segments, &(&1 == "")) do
      :error
    else
      fetch_segments(config, segments)
    end
  end

  @spec fetch!(t(), key()) :: term()
  def fetch!(%__MODULE__{} = config, key) do
    case fetch(config, key) do
      {:ok, value} -> value
      :error -> raise KeyError, key: key, term: config
    end
  end

  @spec get(t(), key(), term()) :: term()
  def get(%__MODULE__{} = config, key, default \\ nil) do
    case fetch(config, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  defp schema(project) do
    repo =
      Zoi.map(
        %{
          "path" => Zoi.string() |> Zoi.min(1) |> Zoi.default(project.root)
        },
        unrecognized_keys: :error
      )
      |> Zoi.default(%{"path" => project.root})

    logs = logs_schema()

    Zoi.map(
      %{
        "version" => Zoi.literal(@current_version) |> Zoi.default(@current_version),
        "repo" => repo,
        "logs" => logs
      },
      unrecognized_keys: :error
    )
  end

  defp build(values, project) do
    %__MODULE__{
      version: values["version"],
      repo: %Repo{path: Path.expand(values["repo"]["path"], project.root)},
      logs: build_logs(values["logs"])
    }
  end

  defp logs_schema do
    defaults = %{
      "enabled" => true,
      "path" => "factory.jsonl",
      "format" => "jsonl",
      "console" => true,
      "include_internal" => false,
      "sync_interval_ms" => 1_000,
      "max_bytes" => 10_485_760,
      "max_files" => 5,
      "compress" => true
    }

    Zoi.map(
      %{
        "enabled" => Zoi.boolean() |> Zoi.default(defaults["enabled"]),
        "path" => safe_log_path_schema(defaults["path"]),
        "format" => Zoi.enum(["jsonl", "text"]) |> Zoi.default(defaults["format"]),
        "console" => Zoi.boolean() |> Zoi.default(defaults["console"]),
        "include_internal" => Zoi.boolean() |> Zoi.default(defaults["include_internal"]),
        "sync_interval_ms" =>
          Zoi.integer() |> Zoi.min(0) |> Zoi.default(defaults["sync_interval_ms"]),
        "max_bytes" => Zoi.integer() |> Zoi.positive() |> Zoi.default(defaults["max_bytes"]),
        "max_files" => Zoi.integer() |> Zoi.min(0) |> Zoi.default(defaults["max_files"]),
        "compress" => Zoi.boolean() |> Zoi.default(defaults["compress"])
      },
      unrecognized_keys: :error
    )
    |> Zoi.default(defaults)
  end

  defp safe_log_path_schema(default) do
    Zoi.string()
    |> Zoi.min(1)
    |> Zoi.refine(fn path ->
      case Path.safe_relative(path, ".") do
        {:ok, relative} when relative in ["", "."] ->
          {:error, "must name a file inside .hancho/logs"}

        {:ok, _relative} ->
          :ok

        :error ->
          {:error, "must be relative to .hancho/logs"}
      end
    end)
    |> Zoi.default(default)
  end

  defp build_logs(values) do
    %Logs{
      enabled: values["enabled"],
      path: values["path"],
      format: log_format(values["format"]),
      console: values["console"],
      include_internal: values["include_internal"],
      sync_interval_ms: values["sync_interval_ms"],
      max_bytes: values["max_bytes"],
      max_files: values["max_files"],
      compress: values["compress"]
    }
  end

  defp log_format("jsonl"), do: :jsonl
  defp log_format("text"), do: :text

  defp fetch_segments(value, []), do: {:ok, value}

  defp fetch_segments(value, [segment | rest]) when is_struct(value) do
    value |> Map.from_struct() |> fetch_segments([segment | rest])
  end

  defp fetch_segments(value, [segment | rest]) when is_map(value) do
    case Enum.find(value, fn {key, _value} -> to_string(key) == segment end) do
      {_key, next} -> fetch_segments(next, rest)
      nil -> :error
    end
  end

  defp fetch_segments(_value, _segments), do: :error

  defp read_error(path, reason) do
    %Error{
      kind: :read,
      path: path,
      message: "Cannot read Hancho configuration at #{path}: #{:file.format_error(reason)}",
      details: reason
    }
  end

  defp decode_error(path, reason) do
    %Error{
      kind: :decode,
      path: path,
      message: "Cannot decode Hancho configuration at #{path}: #{Exception.message(reason)}",
      details: reason
    }
  end

  defp validation_error(path, errors) do
    details =
      Enum.map_join(errors, "; ", fn error ->
        key = Enum.map_join(error.path, ".", &to_string/1)
        if key == "", do: error.message, else: "#{key}: #{error.message}"
      end)

    %Error{
      kind: :validation,
      path: path,
      message: "Invalid Hancho configuration at #{path}: #{details}",
      details: errors
    }
  end
end
