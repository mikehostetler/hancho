defmodule Hancho.CLI.Output do
  @moduledoc false

  alias Hancho.JSON
  alias Hancho.CLI.Result

  @spec print(term(), keyword()) :: :ok
  def print(data, opts \\ [])

  def print(%Result{} = result, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(JSON.encode!(Map.put_new(to_map(result.data), :schema_version, 1)))
    else
      IO.puts(result.text)
    end

    :ok
  end

  def print(data, opts) do
    print(%Result{data: data, text: human_text(data)}, opts)
  end

  @spec error(Exception.t() | String.t(), keyword()) :: :ok
  def error(error, opts \\ []) do
    message = if is_binary(error), do: error, else: Exception.message(error)

    if Keyword.get(opts, :json, false) do
      payload =
        case error do
          %Hancho.Error{} ->
            %{
              schema_version: 1,
              result: "error",
              code: to_string(error.code),
              exit_status: error.exit_status,
              message: message,
              details: error.details
            }

          _ ->
            %{schema_version: 1, result: "error", code: "internal_error", message: message}
        end

      IO.puts(:stderr, JSON.encode!(payload))
    else
      IO.puts(:stderr, "ERROR: #{message}")
    end

    :ok
  end

  defp to_map(map) when is_map(map), do: map
  defp to_map(value), do: %{result: value}

  defp human_text(value) when is_binary(value), do: value
  defp human_text(value), do: inspect(value, pretty: true, limit: :infinity)
end
