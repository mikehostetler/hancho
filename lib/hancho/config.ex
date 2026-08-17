defmodule Hancho.Config do
  @moduledoc """
  Reads and validates repository-local Hancho configuration.

  Use dot-delimited keys to read values:

      {:ok, config} = Hancho.Config.load(project)
      Hancho.Config.get(config, "repo.path")
  """

  alias Hancho.Config.Error
  alias Hancho.Config.Repo
  alias Hancho.Project

  @current_version 1

  @enforce_keys [:version, :repo]
  defstruct [:version, :repo]

  @type t :: %__MODULE__{version: pos_integer(), repo: Repo.t()}
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
      "repo" => %{"path" => config.repo.path}
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

    Zoi.map(
      %{
        "version" => Zoi.literal(@current_version) |> Zoi.default(@current_version),
        "repo" => repo
      },
      unrecognized_keys: :error
    )
  end

  defp build(values, project) do
    %__MODULE__{
      version: values["version"],
      repo: %Repo{path: Path.expand(values["repo"]["path"], project.root)}
    }
  end

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
