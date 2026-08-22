defmodule Hancho.Workflow.ArtifactSpec do
  @moduledoc "A validated JSON artifact contract declared by a workflow."

  @types ["any", "object", "array", "string", "integer", "number", "boolean"]

  @schema Zoi.struct(
            __MODULE__,
            %{
              type: Zoi.enum(@types) |> Zoi.default("object"),
              required: Zoi.array(Zoi.string()) |> Zoi.default([]),
              properties: Zoi.map(Zoi.string(), Zoi.enum(@types)) |> Zoi.default(%{})
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))
  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  def schema, do: @schema
  def new(attributes), do: Zoi.parse(@schema, attributes)

  @spec validate(t(), term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = spec, value) do
    with :ok <- value_type(spec.type, value),
         :ok <- required_fields(spec, value),
         :ok <- property_types(spec, value) do
      :ok
    end
  end

  def to_map(%__MODULE__{} = spec) do
    spec
    |> Map.from_struct()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp value_type("any", _value), do: :ok
  defp value_type("object", value) when is_map(value), do: :ok
  defp value_type("array", value) when is_list(value), do: :ok
  defp value_type("string", value) when is_binary(value), do: :ok
  defp value_type("integer", value) when is_integer(value), do: :ok
  defp value_type("number", value) when is_number(value), do: :ok
  defp value_type("boolean", value) when is_boolean(value), do: :ok
  defp value_type(type, _value), do: {:error, {:artifact_type_mismatch, type}}

  defp required_fields(%{required: []}, _value), do: :ok

  defp required_fields(%{required: required}, value) when is_map(value) do
    case Enum.find(required, &(not has_key?(value, &1))) do
      nil -> :ok
      field -> {:error, {:artifact_required_field_missing, field}}
    end
  end

  defp required_fields(_spec, _value), do: {:error, :artifact_required_fields_need_object}

  defp property_types(%{properties: properties}, value)
       when map_size(properties) > 0 and is_map(value) do
    Enum.reduce_while(properties, :ok, fn {field, type}, :ok ->
      case fetch(value, field) do
        :error ->
          {:cont, :ok}

        {:ok, item} ->
          case value_type(type, item) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:artifact_property_invalid, field, reason}}}
          end
      end
    end)
  end

  defp property_types(_spec, _value), do: :ok

  defp has_key?(map, key), do: match?({:ok, _}, fetch(map, key))

  defp fetch(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        Enum.find_value(map, :error, fn {k, value} -> if to_string(k) == key, do: {:ok, value} end)
    end
  end
end
