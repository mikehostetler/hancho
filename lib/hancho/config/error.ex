defmodule Hancho.Config.Error do
  @moduledoc """
  An error found while Hancho reads or validates configuration.
  """

  @type kind :: :read | :decode | :validation
  @schema Zoi.struct(
            __MODULE__,
            %{
              kind: Zoi.enum([:read, :decode, :validation]),
              path: Zoi.string() |> Zoi.min(1),
              message: Zoi.string() |> Zoi.min(1),
              details: Zoi.any() |> Zoi.default([])
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  defexception Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def new(%__MODULE__{} = error), do: Zoi.parse(@schema, error)
  def new(attributes) when is_list(attributes), do: new(Map.new(attributes))
  def new(attributes) when is_map(attributes), do: Zoi.parse(@schema, attributes)

  @spec new!(map() | keyword() | t()) :: t()
  def new!(attributes), do: Zoi.parse!(@schema, Map.new(attributes))
end
