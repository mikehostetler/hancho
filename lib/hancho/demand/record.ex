defmodule Hancho.Demand.Record do
  @moduledoc "A normalized view of one GitHub demand and its Beadwork execution record."

  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.string() |> Zoi.min(1),
              title: Zoi.string() |> Zoi.min(1),
              github_repository: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              github_node_id: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              github_number: Zoi.integer() |> Zoi.nullish() |> Zoi.default(nil),
              github_url: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              github_status: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              github_parent_node_id: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              beadwork_id: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              beadwork_status: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              beadwork_parent_id: Zoi.string() |> Zoi.nullish() |> Zoi.default(nil),
              mapping_status: Zoi.string() |> Zoi.min(1),
              problems: Zoi.array(Zoi.string()) |> Zoi.default([])
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

  @spec new!(map()) :: t()
  def new!(attributes), do: Zoi.parse!(@schema, attributes)
end
