defmodule Hancho.Workflow.RoleResolver do
  @moduledoc false

  @spec params(Hancho.Workflow.Definition.t(), Hancho.Workflow.Step.t()) :: map()
  def params(_definition, %{role: nil, params: params}), do: params

  def params(_definition, %{action: action, params: params})
      when action != "Hancho.Actions.Implement",
      do: params

  def params(definition, step) do
    role = Map.fetch!(definition.roles, step.role)
    params = step.params
    task_prompt = param(params, "prompt")

    params
    |> put_default("provider", role.provider)
    |> put_default("model", role.model)
    |> put_default("reasoning_effort", role.reasoning_effort)
    |> put_default("cli", role.cli)
    |> put_default("extra_args", role.extra_args)
    |> Map.put(key_for(params, "prompt"), join_prompts(role.prompt, task_prompt))
  end

  defp join_prompts(_role, "$" <> _rest = reference), do: reference
  defp join_prompts(role, nil), do: role
  defp join_prompts(role, task), do: String.trim_trailing(role) <> "\n\n" <> task

  defp put_default(params, _key, nil), do: params
  defp put_default(params, _key, []), do: params

  defp put_default(params, key, value) do
    if has_param?(params, key), do: params, else: Map.put(params, key, value)
  end

  defp has_param?(params, key), do: Enum.any?(Map.keys(params), &(to_string(&1) == key))
  defp key_for(params, key), do: Enum.find(Map.keys(params), key, &(to_string(&1) == key))

  defp param(params, key) do
    Enum.find_value(params, fn {actual, value} -> if to_string(actual) == key, do: value end)
  end
end
