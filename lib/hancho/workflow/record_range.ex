defmodule Hancho.Workflow.RecordRange do
  @moduledoc false

  @spec decode_prefix(Enumerable.t(), binary(), (binary() -> {:ok, map()} | {:error, term()})) ::
          {:ok, [map()]} | {:error, term()}
  def decode_prefix(rows, prefix, decoder) when is_binary(prefix) and is_function(decoder, 1) do
    rows
    |> Enum.reduce_while({:ok, []}, fn
      {key, encoded}, {:ok, records} when is_binary(key) and is_binary(encoded) ->
        if in_prefix?(key, prefix) do
          case decoder.(encoded) do
            {:ok, record} -> {:cont, {:ok, [record | records]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        else
          {:cont, {:ok, records}}
        end

      row, {:ok, _records} ->
        {:halt, {:error, {:invalid_range_row, row}}}
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp in_prefix?(key, prefix) do
    prefix_size = byte_size(prefix)

    case key do
      <<^prefix::binary-size(^prefix_size), _suffix::binary>> -> true
      _other -> false
    end
  end
end
