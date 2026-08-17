defmodule Hancho.Workflow.Step do
  @moduledoc "One named action in a workflow."

  alias Hancho.Workflow.OnError

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string() |> Zoi.min(1),
              action: Zoi.string() |> Zoi.min(1),
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
end
