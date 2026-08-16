defmodule Hancho.JSON do
  @moduledoc false

  @spec encode!(term()) :: String.t()
  def encode!(value) do
    value
    |> normalize()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @spec decode!(iodata()) :: term()
  def decode!(value) do
    value
    |> IO.iodata_to_binary()
    |> :json.decode()
    |> denormalize()
  end

  defp normalize(%_{} = struct), do: struct |> Map.from_struct() |> normalize()

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(nil), do: :null
  defp normalize(:null), do: :null

  defp normalize(atom) when is_atom(atom) and atom not in [true, false, nil],
    do: Atom.to_string(atom)

  defp normalize(value), do: value

  defp denormalize(:null), do: nil

  defp denormalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, denormalize(value)} end)
  end

  defp denormalize(list) when is_list(list), do: Enum.map(list, &denormalize/1)
  defp denormalize(value), do: value
end
