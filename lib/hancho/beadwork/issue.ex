defmodule Hancho.Beadwork.Issue do
  @moduledoc "Validated task data returned by the Beadwork adapter."

  @schema Zoi.struct(
            __MODULE__,
            %{
              id: Zoi.string() |> Zoi.min(1),
              title: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              type: Zoi.string() |> Zoi.min(1),
              status: Zoi.string() |> Zoi.min(1),
              blocked_by: Zoi.array(Zoi.string()) |> Zoi.default([]),
              description: Zoi.string() |> Zoi.default("")
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
  def to_map(%__MODULE__{} = issue) do
    issue
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
