defmodule Hancho.Harness.EventConsole do
  @moduledoc false

  alias Jido.Harness.Event

  @text_types [:thinking_delta, :output_text_delta, :output_text_final]

  @spec write([Event.t()], (String.t() -> term())) :: :ok
  def write(events, writer \\ &IO.puts/1) when is_list(events) and is_function(writer, 1) do
    events
    |> lines()
    |> Enum.each(writer)

    :ok
  end

  @spec lines([Event.t()]) :: [String.t()]
  def lines(events) when is_list(events) do
    events
    |> Enum.chunk_by(&chunk_key/1)
    |> Enum.flat_map(&format_chunk/1)
  end

  defp chunk_key(%Event{provider: provider, type: type}) when type in @text_types,
    do: {provider, type}

  defp chunk_key(%Event{sequence: sequence}), do: {:event, sequence}

  defp format_chunk([%Event{provider: provider, type: type} | _events] = events)
       when type in @text_types do
    text = events |> Enum.map_join(&text/1) |> String.trim()

    if text == "" do
      []
    else
      prefix = if type == :thinking_delta, do: "[#{provider}:thought]", else: "[#{provider}]"
      prefixed_lines(prefix, text)
    end
  end

  defp format_chunk([%Event{provider: provider, type: :tool_call, payload: payload}]) do
    name = payload["name"] || "unknown"
    detail = tool_detail(payload["input"])
    [join_detail("[#{provider}:tool] #{name}", detail)]
  end

  defp format_chunk([%Event{provider: provider, type: :tool_result, payload: payload}]) do
    status = if payload["is_error"], do: "failed", else: "completed"
    call_id = short_call_id(payload["call_id"])
    [join_detail("[#{provider}:tool] #{status}", call_id)]
  end

  defp format_chunk([%Event{provider: provider, type: :file_change, payload: payload}]) do
    detail = payload["path"] || payload["file"] || payload["status"]
    [join_detail("[#{provider}:file] changed", printable(detail))]
  end

  defp format_chunk([%Event{provider: provider, type: :plan_updated, payload: payload}]) do
    detail = payload["summary"] || payload["status"]
    [join_detail("[#{provider}:plan] updated", printable(detail))]
  end

  defp format_chunk([%Event{provider: provider, type: :usage, payload: payload}]) do
    case payload["total_tokens"] do
      total when is_number(total) -> ["[#{provider}:usage] #{total} total tokens"]
      _other -> []
    end
  end

  defp format_chunk([
         %Event{provider: provider, type: :approval_requested, payload: payload}
       ]) do
    detail = payload["description"] || payload["reason"]
    [join_detail("[#{provider}:approval] requested", printable(detail))]
  end

  defp format_chunk([%Event{provider: provider, type: type}])
       when type in [:run_completed, :run_failed, :run_cancelled] do
    status = type |> Atom.to_string() |> String.replace_prefix("run_", "")
    ["[#{provider}] run #{status}"]
  end

  defp format_chunk(_events), do: []

  defp text(%Event{payload: %{"text" => text}}) when is_binary(text), do: text
  defp text(_event), do: ""

  defp prefixed_lines(prefix, text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&(prefix <> " " <> String.trim(&1)))
    |> Enum.reject(&(&1 == prefix <> " "))
  end

  defp tool_detail(input) when is_map(input) do
    detail =
      input["description"] || input["target_file"] || input["target_directory"] ||
        input["path"] || input["pattern"]

    printable(detail)
  end

  defp tool_detail(_input), do: nil

  defp printable(value) when is_binary(value) and value != "", do: value
  defp printable(_value), do: nil

  defp short_call_id(call_id) when is_binary(call_id) do
    if String.length(call_id) > 12,
      do: String.slice(call_id, String.length(call_id) - 12, 12),
      else: call_id
  end

  defp short_call_id(_call_id), do: nil

  defp join_detail(message, nil), do: message
  defp join_detail(message, detail), do: message <> " — " <> detail
end
