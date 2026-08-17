defmodule Hancho.Workflow.RepairRecord do
  @moduledoc "Durable evidence for one coding-agent repair attempt."

  @record_version 1

  @schema Zoi.struct(
            __MODULE__,
            %{
              record_version: Zoi.literal(@record_version) |> Zoi.default(@record_version),
              step: Zoi.string() |> Zoi.min(1),
              attempt: Zoi.integer() |> Zoi.min(1),
              status: Zoi.enum(["running", "completed", "failed", "recovered"]),
              code: Zoi.string() |> Zoi.min(1),
              provider: Zoi.string() |> Zoi.min(1),
              prompt: Zoi.string() |> Zoi.min(1),
              prompt_sha256: Zoi.string() |> Zoi.min(1),
              trigger_error: Zoi.any(),
              result: Zoi.any() |> Zoi.nullish() |> Zoi.default(nil),
              error: Zoi.any() |> Zoi.nullish() |> Zoi.default(nil),
              started_at: Zoi.string() |> Zoi.min(1),
              finished_at: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil)
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
    |> Map.new(fn {key, value} -> {Atom.to_string(key), Hancho.Log.Event.normalize(value)} end)
  end
end
