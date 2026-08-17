defmodule Hancho.Workflow.RunRecord do
  @moduledoc "Validated durable state for one workflow run."

  @record_version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              record_version: Zoi.literal(@record_version) |> Zoi.default(@record_version),
              transition_version: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
              id: Zoi.string() |> Zoi.min(1),
              workflow_name: Zoi.string() |> Zoi.min(1),
              workflow_version: Zoi.integer() |> Zoi.min(1),
              workflow_source_path: Zoi.string() |> Zoi.min(1),
              workflow_yaml: Zoi.string(),
              workflow_sha256: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum(["running", "stopped", "completed", "recovery_required"]),
              current_step: Zoi.string() |> Zoi.nullish(),
              input_json: Zoi.string(),
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

  @spec upgrade(map()) :: map()
  def upgrade(attributes) do
    attributes
    |> Map.put_new("record_version", @record_version)
    |> Map.put_new("transition_version", 0)
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = record) do
    record
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
