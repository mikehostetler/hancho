defmodule Hancho.Command.Result do
  @moduledoc """
  The completed result of an operating-system command.
  """

  @schema Zoi.struct(
            __MODULE__,
            %{
              stdout: Zoi.string(),
              stderr: Zoi.string(),
              exit_status: Zoi.integer() |> Zoi.min(0)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, [Zoi.Error.t()]}
  def new(%__MODULE__{} = result), do: Zoi.parse(@schema, result)
  def new(attributes) when is_list(attributes), do: new(Map.new(attributes))
  def new(attributes) when is_map(attributes), do: Zoi.parse(@schema, attributes)
end
