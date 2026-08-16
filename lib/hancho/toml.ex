defmodule Hancho.TOML do
  @moduledoc false

  alias Hancho.Error

  @spec parse(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def parse(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, {%{}, []}}, &parse_line/2)
    |> case do
      {:ok, {data, _section}} -> {:ok, data}
      {:error, _} = error -> error
    end
  end

  defp parse_line({line, number}, {:ok, {data, section}}) do
    line = line |> strip_comment() |> String.trim()

    cond do
      line == "" ->
        {:cont, {:ok, {data, section}}}

      String.starts_with?(line, "[") and String.ends_with?(line, "]") ->
        value = line |> String.slice(1, String.length(line) - 2) |> String.trim()
        keys = String.split(value, ".", trim: true)

        if keys == [] or Enum.any?(keys, &(not valid_key?(&1))) do
          {:halt, parse_error(number, "Invalid table name")}
        else
          {:cont, {:ok, {ensure_path(data, keys), keys}}}
        end

      true ->
        with [key, raw_value] <- String.split(line, "=", parts: 2),
             key <- String.trim(key),
             true <- valid_key?(key),
             {:ok, value} <- parse_value(String.trim(raw_value)) do
          path = section ++ [key]

          if get_in_path(data, path) == :missing do
            {:cont, {:ok, {put_in_path(data, path, value), section}}}
          else
            {:halt, parse_error(number, "Duplicate key '#{Enum.join(path, ".")}'")}
          end
        else
          _ -> {:halt, parse_error(number, "Invalid key or value")}
        end
    end
  end

  defp parse_value(<<"\"", rest::binary>>) do
    if String.ends_with?(rest, "\"") do
      value = String.slice(rest, 0, String.length(rest) - 1)

      case unescape_string(value) do
        {:ok, decoded} -> {:ok, decoded}
        :error -> :error
      end
    else
      :error
    end
  end

  defp parse_value("true"), do: {:ok, true}
  defp parse_value("false"), do: {:ok, false}

  defp parse_value(<<"[", rest::binary>>) do
    if String.ends_with?(rest, "]") do
      inner = String.slice(rest, 0, String.length(rest) - 1) |> String.trim()

      if inner == "" do
        {:ok, []}
      else
        inner
        |> split_array()
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, values} ->
          case parse_value(String.trim(item)) do
            {:ok, value} when is_binary(value) or is_integer(value) or is_boolean(value) ->
              {:cont, {:ok, [value | values]}}

            _ ->
              {:halt, :error}
          end
        end)
        |> case do
          {:ok, values} -> {:ok, Enum.reverse(values)}
          :error -> :error
        end
      end
    else
      :error
    end
  end

  defp parse_value(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _ -> :error
    end
  end

  defp split_array(value) do
    {items, current, _quoted} =
      value
      |> String.graphemes()
      |> Enum.reduce({[], "", false}, fn
        "\"", {items, current, quoted} -> {items, current <> "\"", not quoted}
        ",", {items, current, false} -> {[current | items], "", false}
        char, {items, current, quoted} -> {items, current <> char, quoted}
      end)

    Enum.reverse([current | items])
  end

  defp strip_comment(line) do
    {text, _quoted} =
      line
      |> String.graphemes()
      |> Enum.reduce_while({"", false}, fn
        "\"", {text, quoted} -> {:cont, {text <> "\"", not quoted}}
        "#", {text, false} -> {:halt, {text, false}}
        char, {text, quoted} -> {:cont, {text <> char, quoted}}
      end)

    text
  end

  defp unescape_string(value) do
    value = String.replace(value, "\\\"", "\"") |> String.replace("\\\\", "\\")
    {:ok, value}
  rescue
    _ -> :error
  end

  defp valid_key?(key), do: Regex.match?(~r/^[A-Za-z0-9_-]+$/, key)

  defp ensure_path(data, []), do: data

  defp ensure_path(data, [key | rest]) do
    child = Map.get(data, key, %{})
    Map.put(data, key, ensure_path(child, rest))
  end

  defp put_in_path(data, [key], value), do: Map.put(data, key, value)

  defp put_in_path(data, [key | rest], value) do
    Map.put(data, key, put_in_path(Map.get(data, key, %{}), rest, value))
  end

  defp get_in_path(data, [key]) do
    if Map.has_key?(data, key), do: Map.fetch!(data, key), else: :missing
  end

  defp get_in_path(data, [key | rest]) do
    case Map.fetch(data, key) do
      {:ok, child} when is_map(child) -> get_in_path(child, rest)
      _ -> :missing
    end
  end

  defp parse_error(line, message) do
    {:error,
     %Error{
       code: :invalid_toml,
       exit_status: 65,
       message: "Invalid TOML at line #{line}: #{message}."
     }}
  end
end
