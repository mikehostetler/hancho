defmodule Hancho.Workflow.Params do
  @moduledoc "Resolves explicit workflow parameter references."

  @spec resolve(term(), map()) :: {:ok, term()} | {:error, String.t()}
  def resolve(value, scope) when is_binary(value) do
    if String.starts_with?(value, "$") do
      resolve_reference(value, scope)
    else
      {:ok, value}
    end
  end

  def resolve(value, scope) when is_list(value) do
    reduce(value, [], fn item, acc -> [item | acc] end, scope, &Enum.reverse/1)
  end

  def resolve(value, scope) when is_map(value) do
    value
    |> Enum.to_list()
    |> reduce(%{}, fn {key, item}, acc -> Map.put(acc, key, item) end, scope, & &1)
  end

  def resolve(value, _scope), do: {:ok, value}

  defp reduce(values, initial, put, scope, finish) do
    Enum.reduce_while(values, {:ok, initial}, fn value, {:ok, acc} ->
      {key, target} = if is_tuple(value), do: value, else: {nil, value}

      case resolve(target, scope) do
        {:ok, resolved} ->
          item = if is_nil(key), do: resolved, else: {key, resolved}
          {:cont, {:ok, put.(item, acc)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, finish.(result)}
      error -> error
    end
  end

  defp resolve_reference(reference, scope) do
    path = reference |> String.trim_leading("$") |> String.split(".")

    case get_in_path(scope, path) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, "Parameter reference was not found: #{reference}"}
    end
  end

  defp get_in_path(value, []), do: {:ok, value}

  defp get_in_path(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> get_in_path(next, rest)
      :error -> :error
    end
  end

  defp get_in_path(_value, _path), do: :error
end
