defmodule Hancho.Workflow.AttentionRecord do
  @moduledoc "Validated durable state for one human decision or answer."

  @record_version 1
  @schema Zoi.struct(
            __MODULE__,
            %{
              record_version: Zoi.literal(@record_version) |> Zoi.default(@record_version),
              transition_version: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
              id: Zoi.string() |> Zoi.min(1),
              run_id: Zoi.string() |> Zoi.min(1),
              step: Zoi.string() |> Zoi.min(1),
              role: Zoi.string() |> Zoi.nullish(),
              kind: Zoi.enum(["approval", "clarification", "scope_exception", "recovery"]),
              title: Zoi.string() |> Zoi.min(1),
              body: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum(["pending", "approved", "rejected", "answered"]),
              response: Zoi.string() |> Zoi.nullish(),
              created_at: Zoi.string() |> Zoi.min(1),
              resolved_at: Zoi.string() |> Zoi.nullish()
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
