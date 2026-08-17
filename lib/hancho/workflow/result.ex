defmodule Hancho.Workflow.Result do
  @moduledoc "The terminal result of one workflow run."

  @schema Zoi.struct(
            __MODULE__,
            %{
              run_id: Zoi.string() |> Zoi.min(1),
              workflow: Zoi.string() |> Zoi.min(1),
              status: Zoi.enum([:completed, :stopped]),
              current_step: Zoi.string() |> Zoi.nullish(),
              outputs: Zoi.map() |> Zoi.default(%{}),
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
end
