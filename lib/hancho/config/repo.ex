defmodule Hancho.Config.Repo do
  @moduledoc """
  Repository values in the Hancho configuration.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{path: Zoi.string() |> Zoi.min(1)},
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def new(%__MODULE__{} = repo), do: Zoi.parse(@schema, repo)
  def new(attributes) when is_list(attributes), do: new(Map.new(attributes))
  def new(attributes) when is_map(attributes), do: Zoi.parse(@schema, attributes)
end
