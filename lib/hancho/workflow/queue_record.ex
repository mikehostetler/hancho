defmodule Hancho.Workflow.QueueRecord do
  @moduledoc "Validated durable state for one foreground queue."

  alias Hancho.Workflow.QueueItemRecord

  @record_version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              record_version: Zoi.literal(@record_version) |> Zoi.default(@record_version),
              transition_version: Zoi.integer() |> Zoi.min(0) |> Zoi.default(0),
              id: Zoi.string() |> Zoi.min(1),
              workflow_name: Zoi.string() |> Zoi.min(1),
              source: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum(["running", "stopped", "completed", "recovery_required"]),
              repository: Zoi.string() |> Zoi.min(1),
              expected_branch: Zoi.string() |> Zoi.min(1),
              expected_head: Zoi.string() |> Zoi.min(1),
              expected_worktrees: Zoi.array(Zoi.map()) |> Zoi.default([]),
              current_position: Zoi.integer() |> Zoi.min(0),
              current_run_id: Zoi.string() |> Zoi.nullish(),
              items: Zoi.array(QueueItemRecord.schema()) |> Zoi.min(1),
              started_at: Zoi.string() |> Zoi.min(1),
              finished_at: Zoi.string() |> Zoi.nullish(),
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
    |> Map.update!(:items, &Enum.map(&1, fn item -> QueueItemRecord.to_map(item) end))
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end
end
