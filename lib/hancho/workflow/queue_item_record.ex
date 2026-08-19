defmodule Hancho.Workflow.QueueItemRecord do
  @moduledoc "Validated durable state for one queue item."

  @schema Zoi.struct(
            __MODULE__,
            %{
              position: Zoi.integer() |> Zoi.min(0),
              issue_id: Zoi.string() |> Zoi.min(1),
              run_id: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum(["pending", "running", "stopped", "completed"]),
              error: Zoi.any() |> Zoi.nullish()
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
  def to_map(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
