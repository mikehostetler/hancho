defmodule Hancho.Workflow.Definition do
  @moduledoc "A validated, sequential workflow definition."

  alias Hancho.Workflow.{ArtifactSpec, OnError, Role, Step}

  @schema Zoi.struct(
            __MODULE__,
            %{
              name: Zoi.string() |> Zoi.min(1),
              version: Zoi.integer() |> Zoi.min(1),
              roles: Zoi.map(Zoi.string(), Role.schema()) |> Zoi.default(%{}),
              artifacts: Zoi.map(Zoi.string(), ArtifactSpec.schema()) |> Zoi.default(%{}),
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
         :ok <- validate_roles(definition),
         :ok <- validate_artifacts(definition),
         :ok <- validate_references(definition.steps),
         :ok <- validate_error_policies(definition.steps) do
      {:ok, definition}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = definition) do
    %{
      "name" => definition.name,
      "version" => definition.version,
      "roles" => Map.new(definition.roles, fn {name, role} -> {name, Role.to_map(role)} end),
      "artifacts" =>
        Map.new(definition.artifacts, fn {name, spec} -> {name, ArtifactSpec.to_map(spec)} end),
      "steps" => Enum.map(definition.steps, &Step.to_map/1)
    }
  end

  defp validate_roles(definition) do
    invalid_name = Enum.find(Map.keys(definition.roles), &(not valid_name?(&1)))

    unknown_role =
      Enum.find(definition.steps, &(&1.role && not Map.has_key?(definition.roles, &1.role)))

    invalid_role =
      Enum.find_value(definition.roles, fn {name, role} ->
        case Role.new(Role.to_map(role)) do
          {:ok, _role} -> nil
          {:error, reason} -> {name, reason}
        end
      end)

    cond do
      invalid_name ->
        {:error, "Invalid role name: #{invalid_name}"}

      invalid_role ->
        {:error, {:invalid_role, elem(invalid_role, 0), elem(invalid_role, 1)}}

      unknown_role ->
        {:error, "Step '#{unknown_role.name}' uses unknown role '#{unknown_role.role}'."}

      true ->
        :ok
    end
  end

  defp validate_artifacts(definition) do
    invalid_name = Enum.find(Map.keys(definition.artifacts), &(not valid_name?(&1)))

    if invalid_name do
      {:error, "Invalid artifact name: #{invalid_name}"}
    else
      definition.steps
      |> Enum.reduce_while({:ok, MapSet.new()}, fn step, {:ok, produced} ->
        with :ok <- declared_consumers(step, definition.artifacts, produced),
             :ok <- declared_producer(step, definition.artifacts, produced) do
          {:cont,
           {:ok, if(step.produces, do: MapSet.put(produced, step.produces), else: produced)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _produced} -> :ok
        error -> error
      end
    end
  end

  defp declared_consumers(step, declared, produced) do
    case Enum.find(step.consumes, fn name ->
           not Map.has_key?(declared, name) or not MapSet.member?(produced, name)
         end) do
      nil -> :ok
      name -> {:error, "Step '#{step.name}' consumes unavailable artifact '#{name}'."}
    end
  end

  defp declared_producer(%{produces: nil}, _declared, _produced), do: :ok

  defp declared_producer(step, declared, produced) do
    cond do
      not Map.has_key?(declared, step.produces) ->
        {:error, "Step '#{step.name}' produces undeclared artifact '#{step.produces}'."}

      MapSet.member?(produced, step.produces) ->
        {:error, "Artifact '#{step.produces}' has more than one producer."}

      true ->
        :ok
    end
  end

  defp validate_error_policies(steps) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case OnError.validate(step.action, step.name, step.on_error) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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

  defp valid_name?(name), do: is_binary(name) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, name)

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
