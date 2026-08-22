defmodule Hancho.Workflow.HandoffRecord do
  @moduledoc "Validated durable state for one role handoff."

  @record_version 1
  @schema Zoi.struct(
            __MODULE__,
            %{
              record_version: Zoi.literal(@record_version) |> Zoi.default(@record_version),
              transition_version: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
              id: Zoi.string() |> Zoi.min(1),
              run_id: Zoi.string() |> Zoi.min(1),
              from_role: Zoi.string() |> Zoi.min(1),
              to_role: Zoi.string() |> Zoi.min(1),
              from_step: Zoi.string() |> Zoi.min(1),
              to_step: Zoi.string() |> Zoi.min(1),
              artifact: Zoi.string() |> Zoi.nullish(),
              payload_json: Zoi.string(),
              status: Zoi.enum(["ready", "accepted", "completed", "rejected"]),
              created_at: Zoi.string() |> Zoi.min(1),
              accepted_at: Zoi.string() |> Zoi.nullish(),
              completed_at: Zoi.string() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)
  def schema, do: @schema
  def new(value), do: Zoi.parse(@schema, value)

  def upgrade(value),
    do: value |> Map.put_new("record_version", 1) |> Map.put_new("transition_version", 0)

  def to_map(record),
    do: record |> Map.from_struct() |> Map.new(fn {k, v} -> {to_string(k), v} end)
end
