defmodule Hancho.TOML do
  @moduledoc false

  alias Hancho.Error

  @spec parse(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def parse(text) when is_binary(text) do
    case TomlElixir.decode(text, spec: :"1.0.0") do
      {:ok, data} -> {:ok, data}
      {:error, error} -> {:error, parse_error(text, Exception.message(error))}
    end
  end

  defp parse_error(text, reason) do
    line = duplicate_line(text, reason)
    location = if line, do: " at line #{line}", else: ""

    %Error{
      code: :invalid_toml,
      exit_status: 65,
      message: "Invalid TOML#{location}: #{reason}."
    }
  end

  defp duplicate_line(text, "Duplicate key " <> path) do
    key = path |> String.split(".") |> List.last()
    pattern = ~r/^\s*#{Regex.escape(key)}\s*=/

    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _number} -> Regex.match?(pattern, line) end)
    |> List.last()
    |> case do
      {_line, number} -> number
      nil -> nil
    end
  end

  defp duplicate_line(_text, _reason), do: nil
end
