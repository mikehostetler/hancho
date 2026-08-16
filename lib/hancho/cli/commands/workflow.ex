defmodule Hancho.CLI.Commands.Workflow do
  @moduledoc false
  @behaviour Hancho.CLI.Command

  alias Hancho.CLI.Result
  alias Hancho.Harness.Router
  alias Hancho.{Config, Error, Repository}
  alias Hancho.Workflow.{Definition, Registry}

  @impl true
  def execute(["list"], _options) do
    workflows = Enum.map(Registry.list(), &summary/1)

    text =
      Enum.map_join(workflows, "\n", &"#{&1.name}.v#{&1.version} initial=#{&1.initial_state}")

    %Result{data: %{result: "ok", workflows: workflows}, text: text}
  end

  def execute(["show", name], _options) do
    with {:ok, definition} <- Registry.fetch(name) do
      data = detail(definition)
      %Result{data: Map.put(data, :result, "ok"), text: Hancho.JSON.encode!(data)}
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(["validate", name], options) do
    with {:ok, definition} <- Registry.fetch(name),
         :ok <- validate_definition(definition),
         {:ok, repository} <- Repository.discover(Keyword.get(options, :repo, File.cwd!())),
         {:ok, config} <- Config.load(repository),
         :ok <- Router.validate_routes(config, [definition]) do
      %Result{
        data: %{
          result: "ok",
          workflow: name,
          version: definition.version,
          config_hash: config.hash
        },
        text: "#{name}.v#{definition.version} and its harness routes are valid."
      }
    else
      {:error, %Error{} = error} -> raise error
    end
  end

  def execute(_args, _options) do
    raise Error,
      code: :invalid_arguments,
      exit_status: 64,
      message: "Usage: hancho workflow list|show NAME|validate NAME"
  end

  defp summary(definition) do
    %{
      name: definition.name,
      version: definition.version,
      initial_state: definition.initial_state,
      terminal_states: definition.terminal_states
    }
  end

  defp detail(definition) do
    %{
      name: definition.name,
      version: definition.version,
      initial_state: definition.initial_state,
      terminal_states: definition.terminal_states,
      states: definition.states,
      stations: Enum.map(definition.stations, fn {_id, station} -> Map.from_struct(station) end),
      transitions: Enum.map(definition.transitions, &Map.from_struct/1)
    }
  end

  defp validate_definition(definition) do
    case Definition.validate(definition) do
      [] ->
        :ok

      errors ->
        {:error,
         %Error{
           code: :invalid_workflow,
           exit_status: 78,
           message: Enum.join(errors, "; ")
         }}
    end
  end
end
