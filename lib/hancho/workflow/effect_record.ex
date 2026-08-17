defmodule Hancho.Workflow.EffectRecord do
  @moduledoc "Validated durable intent and receipt for one external effect."

  @record_version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              record_version: Zoi.literal(@record_version) |> Zoi.default(@record_version),
              transition_version: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
              run_id: Zoi.string() |> Zoi.min(1),
              step_position: Zoi.integer() |> Zoi.min(0),
              key: Zoi.string() |> Zoi.min(1),
              kind: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum(["intended", "applied"]),
              intent_json: Zoi.string(),
              receipt_json: Zoi.string() |> Zoi.nullish(),
              attempt: Zoi.integer() |> Zoi.min(1),
              started_at: Zoi.string() |> Zoi.min(1),
              applied_at: Zoi.string() |> Zoi.nullish(),
              error_json: Zoi.string() |> Zoi.nullish()
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
