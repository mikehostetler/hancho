defmodule Hancho.Log.Event do
  @moduledoc """
  A normalized factory activity event.
  """

  @schema_version 1
  @levels [:debug, :info, :notice, :warning, :error, :critical, :alert, :emergency]

  @schema Zoi.struct(
            __MODULE__,
            %{
              schema_version: Zoi.literal(@schema_version),
              sequence: Zoi.integer() |> Zoi.min(0),
              timestamp:
                Zoi.string()
                |> Zoi.refine(&__MODULE__.valid_timestamp?/1),
              level: Zoi.enum(@levels),
              event: Zoi.string() |> Zoi.min(1),
              message: Zoi.string(),
              message_encoding: Zoi.enum([:utf8, :base64]),
              metadata: Zoi.map()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @doc false
  def valid_timestamp?(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, _offset} -> :ok
      {:error, _reason} -> {:error, "must be an ISO 8601 timestamp"}
    end
  end

  @spec new(iodata(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(message, options \\ []) do
    level = Keyword.get(options, :level, :info)
    event = Keyword.get(options, :event, "activity.output")
    sequence = Keyword.get(options, :sequence, 0)
    timestamp = Keyword.get_lazy(options, :timestamp, &DateTime.utc_now/0)
    metadata = Keyword.get(options, :metadata, %{})

    with {:ok, message, encoding} <- normalize_message(message),
         {:ok, timestamp} <- normalize_timestamp(timestamp),
         {:ok, metadata} <- normalize_metadata(metadata) do
      attributes = %{
        schema_version: @schema_version,
        sequence: sequence,
        timestamp: timestamp,
        level: level,
        event: event,
        message: message,
        message_encoding: encoding,
        metadata: metadata
      }

      case Zoi.parse(@schema, attributes) do
        {:ok, event} -> {:ok, event}
        {:error, errors} -> {:error, field_error(attributes, errors)}
      end
    end
  rescue
    error -> {:error, {:invalid_message, error}}
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "schema_version" => event.schema_version,
      "sequence" => event.sequence,
      "timestamp" => event.timestamp,
      "level" => Atom.to_string(event.level),
      "event" => event.event,
      "message" => event.message,
      "message_encoding" => Atom.to_string(event.message_encoding),
      "metadata" => event.metadata
    }
  end

  @spec normalize(term()) :: term()
  def normalize(nil), do: nil
  def normalize(value) when is_boolean(value), do: value
  def normalize(value) when is_integer(value) or is_float(value), do: value
  def normalize(value) when is_atom(value), do: Atom.to_string(value)

  def normalize(value) when is_binary(value) do
    if String.valid?(value) do
      value
    else
      %{"data" => Base.encode64(value), "encoding" => "base64"}
    end
  end

  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def normalize(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def normalize(%Date{} = value), do: Date.to_iso8601(value)
  def normalize(%Time{} = value), do: Time.to_iso8601(value)
  def normalize(value) when is_struct(value), do: inspect(value)
  def normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  def normalize(value) when is_tuple(value), do: value |> Tuple.to_list() |> normalize()

  def normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {normalize_key(key), normalize(item)} end)
  end

  def normalize(value), do: inspect(value)

  defp normalize_message(message) do
    message = IO.iodata_to_binary(message)

    if String.valid?(message) do
      {:ok, message, :utf8}
    else
      {:ok, Base.encode64(message), :base64}
    end
  end

  defp normalize_timestamp(%DateTime{} = timestamp),
    do: {:ok, DateTime.to_iso8601(timestamp)}

  defp normalize_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, _datetime, _offset} -> {:ok, timestamp}
      {:error, _reason} -> {:error, {:invalid_timestamp, timestamp}}
    end
  end

  defp normalize_timestamp(timestamp), do: {:error, {:invalid_timestamp, timestamp}}

  defp normalize_metadata(metadata) when is_list(metadata) do
    if Keyword.keyword?(metadata) do
      {:ok, metadata |> Map.new() |> normalize()}
    else
      {:error, {:invalid_metadata, metadata}}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: {:ok, normalize(metadata)}
  defp normalize_metadata(metadata), do: {:error, {:invalid_metadata, metadata}}

  defp field_error(attributes, errors) do
    cond do
      attributes.level not in @levels ->
        {:invalid_level, attributes.level}

      not (is_binary(attributes.event) and byte_size(attributes.event) > 0) ->
        {:invalid_event, attributes.event}

      not (is_integer(attributes.sequence) and attributes.sequence >= 0) ->
        {:invalid_sequence, attributes.sequence}

      true ->
        {:invalid_event, errors}
    end
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: inspect(key)
end
