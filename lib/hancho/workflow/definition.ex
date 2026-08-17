defmodule Hancho.Workflow.Definition do
  @moduledoc "A validated, sequential workflow definition."

  alias Hancho.Workflow.Step

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string() |> Zoi.min(1),
              version: Zoi.integer() |> Zoi.min(1),
              steps: Zoi.array(Step.schema()) |> Zoi.min(1)
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @spec schema() :: Zoi.schema()
  def schema, do: @schema

  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, definition} <- Zoi.parse(@schema, attributes),
         :ok <- validate_names(definition.steps),
         :ok <- validate_references(definition.steps) do
      {:ok, definition}
    end
  end

  defp validate_names(steps) do
    names = Enum.map(steps, & &1.name)

    cond do
      Enum.any?(names, &(not Regex.match?(~r/^[a-z][a-z0-9_]*$/, &1))) ->
        {:error, "Step names must use lower-case letters, digits, and underscores."}

      length(names) != length(Enum.uniq(names)) ->
        {:error, "Step names must be unique."}

      true ->
        :ok
    end
  end

  defp validate_references(steps) do
    steps
    |> Enum.reduce_while(MapSet.new(), fn step, prior ->
      case referenced_steps(step.params) |> Enum.find(&(not MapSet.member?(prior, &1))) do
        nil -> {:cont, MapSet.put(prior, step.name)}
        name -> {:halt, {:error, "Step '#{step.name}' refers to unavailable step '#{name}'."}}
      end
    end)
    |> case do
      %MapSet{} -> :ok
      error -> error
    end
  end

  defp referenced_steps(value) when is_binary(value) do
    case Regex.run(~r/^\$steps\.([a-z][a-z0-9_]*)\./, value) do
      [_, name] -> [name]
      nil -> []
    end
  end

  defp referenced_steps(value) when is_list(value), do: Enum.flat_map(value, &referenced_steps/1)

  defp referenced_steps(value) when is_map(value) do
    value |> Map.values() |> Enum.flat_map(&referenced_steps/1)
  end

  defp referenced_steps(_value), do: []
end
