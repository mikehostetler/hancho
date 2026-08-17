defmodule Hancho.Workflow.Executor do
  @moduledoc false

  @spec run(module(), map(), map()) :: {:ok, map()} | {:error, term()}
  def run(action, params, context) do
    with {:ok, _applications} <- Application.ensure_all_started(:jido_action) do
      params = atomize_parameter_keys(action, params)

      Jido.Exec.run(action, params, context,
        max_retries: 0,
        timeout: execution_timeout(action, params)
      )
    end
  end

  defp execution_timeout(_action, %{timeout_ms: timeout})
       when is_integer(timeout) and timeout > 0,
       do: timeout + 90_000

  defp execution_timeout(_action, _params), do: 30_000

  defp atomize_parameter_keys(action, params) do
    allowed_keys =
      action.schema().fields
      |> field_names()
      |> Map.new(&{Atom.to_string(&1), &1})

    Map.new(params, fn
      {key, value} when is_binary(key) -> {Map.get(allowed_keys, key, key), value}
      pair -> pair
    end)
  end

  defp field_names(fields) when is_map(fields), do: Map.keys(fields)
  defp field_names(fields) when is_list(fields), do: Keyword.keys(fields)
end
