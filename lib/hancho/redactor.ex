defmodule Hancho.Redactor do
  @moduledoc "Redacts configured patterns and known secret environment values before persistence."

  @default_patterns [
    ~r/(?i)(authorization:[ ]*bearer[ ]+)[^[:space:]]+/,
    ~r/(?i)((password|token|secret|api[_-]?key)[=:])[^[:space:]]+/
  ]

  @spec redact(binary(), map()) :: binary()
  def redact(content, loaded_config) when is_binary(content) do
    if String.valid?(content) do
      content
      |> redact_patterns(configured_patterns(loaded_config))
      |> redact_known_tokens(known_tokens(loaded_config.data))
    else
      "[INVALID UTF-8 OUTPUT REDACTED: #{byte_size(content)} bytes]"
    end
  end

  defp configured_patterns(config) do
    patterns = get_in(config.data, ["redaction", "patterns"]) || []

    @default_patterns ++
      Enum.flat_map(patterns, fn pattern ->
        case Regex.compile(pattern) do
          {:ok, regex} -> [regex]
          {:error, _reason} -> []
        end
      end)
  end

  defp redact_patterns(content, patterns) do
    Enum.reduce(patterns, content, fn pattern, safe ->
      Regex.replace(pattern, safe, "[REDACTED]")
    end)
  end

  defp redact_known_tokens(content, tokens) do
    Enum.reduce(tokens, content, fn token, safe -> String.replace(safe, token, "[REDACTED]") end)
  end

  defp known_tokens(config) do
    config
    |> secret_environment_names([])
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case System.get_env(name) do
        value when is_binary(value) and byte_size(value) >= 4 -> [value]
        _ -> []
      end
    end)
  end

  defp secret_environment_names(map, names) when is_map(map) do
    Enum.reduce(map, names, fn {key, value}, acc ->
      cond do
        is_map(value) -> secret_environment_names(value, acc)
        secret_key?(key) and is_binary(value) -> [value | acc]
        true -> acc
      end
    end)
  end

  defp secret_environment_names(_value, names), do: names

  defp secret_key?(key),
    do: Regex.match?(~r/(password|secret|token|api[_-]?key)/i, to_string(key))
end
