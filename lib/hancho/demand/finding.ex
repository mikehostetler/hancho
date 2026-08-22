defmodule Hancho.Demand.Finding do
  @moduledoc "A mapping audit finding."

  @schema Zoi.struct(
            __MODULE__,
            %{
              severity: Zoi.string() |> Zoi.min(1),
              code: Zoi.string() |> Zoi.min(1),
              identity: Zoi.string() |> Zoi.min(1),
              message: Zoi.string() |> Zoi.min(1)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema
  @spec new!(map()) :: t()
  def new!(attributes), do: Zoi.parse!(@schema, attributes)
end
