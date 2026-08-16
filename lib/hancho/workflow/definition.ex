defmodule Hancho.Workflow.Definition do
  @moduledoc "A versioned, validated workflow state-machine definition."

  alias Hancho.Workflow.{Station, Transition}

  @enforce_keys [
    :name,
    :version,
    :initial_state,
    :terminal_states,
    :states,
    :stations,
    :transitions
  ]
  defstruct [:name, :version, :initial_state, :terminal_states, :states, :stations, :transitions]

  @type t :: %__MODULE__{
          name: String.t(),
          version: pos_integer(),
          initial_state: String.t(),
          terminal_states: [String.t()],
          states: [String.t()],
          stations: %{String.t() => Station.t()},
          transitions: [Transition.t()]
        }

  @spec new(keyword()) :: {:ok, t()} | {:error, [String.t()]}
  def new(attributes) do
    states = Keyword.fetch!(attributes, :states)
    stations = Keyword.fetch!(attributes, :stations)
    transitions = Keyword.fetch!(attributes, :transitions)

    definition = %__MODULE__{
      name: Keyword.fetch!(attributes, :name),
      version: Keyword.fetch!(attributes, :version),
      initial_state: Keyword.fetch!(attributes, :initial_state),
      terminal_states: Keyword.fetch!(attributes, :terminal_states),
      states: states,
      stations: Map.new(stations, &{&1.id, &1}),
      transitions: transitions
    }

    duplicate_errors =
      duplicate_errors(states, "state") ++
        duplicate_errors(Enum.map(stations, & &1.id), "station") ++
        duplicate_errors(Enum.map(transitions, &{&1.from, &1.event}), "transition")

    case duplicate_errors ++ validate(definition) do
      [] -> {:ok, definition}
      errors -> {:error, errors}
    end
  end

  @spec new!(keyword()) :: t()
  def new!(attributes) do
    case new(attributes) do
      {:ok, definition} -> definition
      {:error, errors} -> raise ArgumentError, Enum.join(errors, "; ")
    end
  end

  @spec validate(t()) :: [String.t()]
  def validate(definition) do
    []
    |> validate_identity(definition)
    |> validate_state_references(definition)
    |> validate_station_references(definition)
    |> validate_reachability(definition)
    |> Enum.reverse()
  end

  defp validate_identity(errors, definition) do
    errors =
      if is_binary(definition.name) and definition.name != "",
        do: errors,
        else: ["workflow name is required" | errors]

    errors =
      if is_integer(definition.version) and definition.version > 0,
        do: errors,
        else: ["workflow version must be positive" | errors]

    errors
  end

  defp validate_state_references(errors, definition) do
    errors =
      if definition.initial_state in definition.states,
        do: errors,
        else: ["initial state is unknown" | errors]

    errors =
      Enum.reduce(definition.terminal_states, errors, fn state, acc ->
        if state in definition.states,
          do: acc,
          else: ["terminal state '#{state}' is unknown" | acc]
      end)

    Enum.reduce(definition.transitions, errors, fn transition, acc ->
      acc =
        if transition.from in definition.states,
          do: acc,
          else: ["transition source '#{transition.from}' is unknown" | acc]

      if transition.to in definition.states,
        do: acc,
        else: ["transition target '#{transition.to}' is unknown" | acc]
    end)
  end

  defp validate_station_references(errors, definition) do
    Enum.reduce(definition.transitions, errors, fn transition, acc ->
      Enum.reduce(transition.actions, acc, fn action, nested ->
        station = Map.get(action, :station) || Map.get(action, "station")

        if is_nil(station) or Map.has_key?(definition.stations, station) do
          nested
        else
          ["action uses unknown station '#{station}'" | nested]
        end
      end)
    end)
  end

  defp validate_reachability(errors, definition) do
    reachable = reachable_states(definition, MapSet.new([definition.initial_state]))
    unreachable = Enum.reject(definition.states, &MapSet.member?(reachable, &1))

    Enum.reduce(unreachable, errors, fn state, acc ->
      ["state '#{state}' is unreachable" | acc]
    end)
  end

  defp reachable_states(definition, known) do
    expanded =
      Enum.reduce(definition.transitions, known, fn transition, acc ->
        if MapSet.member?(acc, transition.from), do: MapSet.put(acc, transition.to), else: acc
      end)

    if MapSet.equal?(known, expanded), do: known, else: reachable_states(definition, expanded)
  end

  defp duplicate_errors(values, kind) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> "duplicate #{kind} #{inspect(value)}" end)
  end
end
