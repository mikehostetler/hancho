defmodule Hancho.Workflow.StepRecord do
  @moduledoc "Validated durable state for one workflow step."

  @record_version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              record_version: Zoi.literal(@record_version) |> Zoi.default(@record_version),
              transition_version: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
              position: Zoi.integer() |> Zoi.min(0),
              name: Zoi.string() |> Zoi.min(1),
              action: Zoi.string() |> Zoi.min(1),
              status:
                Zoi.enum([
                  "running",
                  "retry_pending",
                  "stopped",
                  "completed",
                  "recovery_required"
                ]),
              params_json: Zoi.string(),
              result_json: Zoi.string() |> Zoi.nullish(),
              started_at: Zoi.string() |> Zoi.min(1),
              finished_at: Zoi.string() |> Zoi.nullish(),
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
