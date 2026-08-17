defmodule Hancho.Config.Logs do
  @moduledoc """
  Options for repository-local factory activity logs.
  """

  @defaults %{
    enabled: true,
    path: "factory.jsonl",
    format: :jsonl,
    console: true,
    include_internal: false,
    sync_interval_ms: 1_000,
    max_bytes: 10_485_760,
    max_files: 5,
    compress: true
  }

  @type format :: :jsonl | :text

  @path_schema Zoi.string()
               |> Zoi.min(1)
               |> Zoi.refine(&__MODULE__.valid_path?/1)

  @schema Zoi.struct(
            __MODULE__,
            %{
              enabled: Zoi.boolean() |> Zoi.default(@defaults.enabled),
              path: @path_schema |> Zoi.default(@defaults.path),
              format: Zoi.enum([:jsonl, :text]) |> Zoi.default(@defaults.format),
              console: Zoi.boolean() |> Zoi.default(@defaults.console),
              include_internal: Zoi.boolean() |> Zoi.default(@defaults.include_internal),
              sync_interval_ms:
                Zoi.integer() |> Zoi.min(0) |> Zoi.default(@defaults.sync_interval_ms),
              max_bytes: Zoi.integer() |> Zoi.positive() |> Zoi.default(@defaults.max_bytes),
              max_files: Zoi.integer() |> Zoi.min(0) |> Zoi.default(@defaults.max_files),
              compress: Zoi.boolean() |> Zoi.default(@defaults.compress)
            },
            coerce: true
          )

  @input_schema Zoi.map(
                  %{
                    "enabled" => Zoi.boolean() |> Zoi.default(@defaults.enabled),
                    "path" => @path_schema |> Zoi.default(@defaults.path),
                    "format" =>
                      Zoi.enum(["jsonl", "text"])
                      |> Zoi.default(Atom.to_string(@defaults.format)),
                    "console" => Zoi.boolean() |> Zoi.default(@defaults.console),
                    "include_internal" =>
                      Zoi.boolean() |> Zoi.default(@defaults.include_internal),
                    "sync_interval_ms" =>
                      Zoi.integer()
                      |> Zoi.min(0)
                      |> Zoi.default(@defaults.sync_interval_ms),
                    "max_bytes" =>
                      Zoi.integer() |> Zoi.positive() |> Zoi.default(@defaults.max_bytes),
                    "max_files" =>
                      Zoi.integer() |> Zoi.min(0) |> Zoi.default(@defaults.max_files),
                    "compress" => Zoi.boolean() |> Zoi.default(@defaults.compress)
                  },
                  unrecognized_keys: :error
                )
                |> Zoi.default(
                  Map.new(@defaults, fn {key, value} ->
                    value = if key == :format, do: Atom.to_string(value), else: value
                    {Atom.to_string(key), value}
                  end)
                )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  def valid_path?(path) do
    case Path.safe_relative(path, ".") do
      {:ok, relative} when relative in ["", "."] ->
        {:error, "must name a file inside .hancho/logs"}

      {:ok, _relative} ->
        :ok

      :error ->
        {:error, "must be relative to .hancho/logs"}
    end
  end

  @spec input_schema() :: Zoi.schema()
  def input_schema, do: @input_schema

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def new(%__MODULE__{} = logs), do: Zoi.parse(@schema, logs)
  def new(attributes) when is_list(attributes), do: new(Map.new(attributes))
  def new(attributes) when is_map(attributes), do: Zoi.parse(@schema, attributes)

  @spec from_input(map()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def from_input(values) when is_map(values) do
    new(%{
      enabled: values["enabled"],
      path: values["path"],
      format: format(values["format"]),
      console: values["console"],
      include_internal: values["include_internal"],
      sync_interval_ms: values["sync_interval_ms"],
      max_bytes: values["max_bytes"],
      max_files: values["max_files"],
      compress: values["compress"]
    })
  end

  @spec to_input(t()) :: map()
  def to_input(%__MODULE__{} = logs) do
    %{
      "enabled" => logs.enabled,
      "path" => logs.path,
      "format" => Atom.to_string(logs.format),
      "console" => logs.console,
      "include_internal" => logs.include_internal,
      "sync_interval_ms" => logs.sync_interval_ms,
      "max_bytes" => logs.max_bytes,
      "max_files" => logs.max_files,
      "compress" => logs.compress
    }
  end

  defp format("jsonl"), do: :jsonl
  defp format("text"), do: :text
end
