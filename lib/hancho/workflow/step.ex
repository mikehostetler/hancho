defmodule Hancho.Workflow.Step do
  @moduledoc "One named action in a workflow."

  alias Hancho.Workflow.OnError

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string() |> Zoi.min(1),
              action: Zoi.string() |> Zoi.min(1),
              role: Zoi.string() |> Zoi.min(1) |> Zoi.nullish() |> Zoi.default(nil),
              consumes: Zoi.array(Zoi.string()) |> Zoi.default([]),
              produces: Zoi.string() |> Zoi.min(1) |> Zoi.nullish() |> Zoi.default(nil),
              params: Zoi.map() |> Zoi.default(%{}),
              on_error: OnError.schema() |> Zoi.nullish() |> Zoi.default(nil)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attributes), do: Zoi.parse(@schema, attributes)

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = step) do
    step
    |> Map.from_struct()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.update(:on_error, nil, fn
      nil -> nil
      policy -> Map.from_struct(policy)
    end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
