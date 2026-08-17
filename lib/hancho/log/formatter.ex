defmodule Hancho.Log.Formatter do
  @moduledoc false

  alias Hancho.Log.Event

  def format(%{meta: %{hancho_event: event}}, %{format: :jsonl}) do
    [Jason.encode_to_iodata!(event), "\n"]
  end

  def format(%{meta: %{hancho_event: event}}, %{format: :text}) do
    metadata = Jason.encode!(event["metadata"])

    [
      event["timestamp"],
      " ",
      String.upcase(event["level"]),
      " ",
      event["event"],
      " ",
      escape_line(event["message"]),
      " ",
      metadata,
      "\n"
    ]
  end

  def format(event, %{format: format}) do
    normalized = normalize_internal(event)

    case format do
      :jsonl -> [Jason.encode_to_iodata!(normalized), "\n"]
      :text -> format_internal_text(normalized)
    end
  end

  defp normalize_internal(event) do
    metadata =
      event.meta
      |> Map.drop([:hancho_event, :time])
      |> Event.normalize()

    %{
      "schema_version" => 1,
      "sequence" => 0,
      "timestamp" => timestamp(event.meta[:time]),
      "level" => Atom.to_string(event.level),
      "event" => "hancho.internal",
      "message" => event |> message() |> Event.normalize(),
      "message_encoding" => "utf8",
      "metadata" => metadata
    }
  end

  defp format_internal_text(event) do
    [
      event["timestamp"],
      " ",
      String.upcase(event["level"]),
      " ",
      event["event"],
      " ",
      escape_line(event["message"]),
      " ",
      Jason.encode!(event["metadata"]),
      "\n"
    ]
  end

  defp message(%{msg: {:string, value}}), do: IO.chardata_to_string(value)
  defp message(%{msg: {:report, value}}), do: inspect(value)

  defp message(%{msg: {format, arguments}}) do
    format |> :io_lib.format(arguments) |> IO.chardata_to_string()
  end

  defp message(%{msg: value}), do: inspect(value)

  defp timestamp(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp timestamp(microseconds) do
    microseconds |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601()
  end

  defp escape_line(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\r", "\\r")
    |> String.replace("\n", "\\n")
  end
end
