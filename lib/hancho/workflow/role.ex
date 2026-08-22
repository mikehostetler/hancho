defmodule Hancho.Workflow.Role do
  @moduledoc "A reusable CLI-agent role declared by a workflow."

  @schema Zoi.struct(
            __MODULE__,
            %{
              provider: Zoi.string() |> Zoi.min(1),
              prompt: Zoi.string() |> Zoi.min(1) |> Zoi.nullish() |> Zoi.default(nil),
              prompt_file: Zoi.string() |> Zoi.min(1) |> Zoi.nullish() |> Zoi.default(nil),
              cli: Zoi.string() |> Zoi.min(1) |> Zoi.nullish() |> Zoi.default(nil),
              model: Zoi.string() |> Zoi.min(1) |> Zoi.nullish() |> Zoi.default(nil),
              reasoning_effort:
                Zoi.enum(["low", "medium", "high", "xhigh"])
                |> Zoi.nullish()
                |> Zoi.default(nil),
              extra_args: Zoi.array(Zoi.string()) |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, role} <- Zoi.parse(@schema, attributes),
         :ok <- one_prompt_source(role) do
      {:ok, role}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = role) do
    role
    |> Map.from_struct()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp one_prompt_source(%{prompt: prompt, prompt_file: file})
       when is_binary(prompt) and is_binary(file),
       do: {:error, "A role must set either prompt or prompt_file, not both."}

  defp one_prompt_source(%{prompt: nil, prompt_file: nil}),
    do: {:error, "A role must set prompt or prompt_file."}

  defp one_prompt_source(_role), do: :ok
end
