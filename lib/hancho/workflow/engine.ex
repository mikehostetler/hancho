defmodule Hancho.Workflow.Engine do
  @moduledoc "The pure Hancho transition function."

  alias Hancho.Workflow.{Definition, Event, Rejection}

  @spec transition(Definition.t(), String.t(), Event.t() | String.t(), map()) ::
          {:ok, map()} | {:error, Rejection.t()}
  def transition(definition, current_state, event, facts \\ %{})

  def transition(%Definition{} = definition, current_state, event_name, facts)
      when is_binary(event_name) do
    transition(definition, current_state, %Event{name: event_name}, facts)
  end

  def transition(%Definition{} = definition, current_state, %Event{} = event, facts) do
    cond do
      event.expected_state && event.expected_state != current_state ->
        {:error,
         rejection(
           :stale_event,
           current_state,
           event.name,
           "Event expected state '#{event.expected_state}', not '#{current_state}'."
         )}

      true ->
        case Enum.find(
               definition.transitions,
               &(&1.from == current_state and &1.event == event.name)
             ) do
          nil ->
            {:error,
             rejection(
               :invalid_event,
               current_state,
               event.name,
               "Event '#{event.name}' is not valid in state '#{current_state}'."
             )}

          transition ->
            case missing_guards(transition.guards, facts) do
              [] ->
                {:ok,
                 %{
                   prior_state: current_state,
                   state: transition.to,
                   event: event.name,
                   actions: transition.actions,
                   terminal: transition.to in definition.terminal_states
                 }}

              missing ->
                {:error,
                 %Rejection{
                   code: :guard_rejected,
                   state: current_state,
                   event: event.name,
                   missing: missing,
                   message: "Event '#{event.name}' is missing required authority or evidence."
                 }}
            end
        end
    end
  end

  defp missing_guards(guards, facts) do
    Enum.reject(guards, fn
      {:fact, name} -> get_in(facts, [:facts, name]) == true
      {:artifact, kind} -> kind in Map.get(facts, :artifacts, [])
      {:decision, kind} -> get_in(facts, [:decisions, kind]) == "approved"
      {:authority, profile} -> profile in Map.get(facts, :authorities, [])
    end)
  end

  defp rejection(code, state, event, message) do
    %Rejection{code: code, state: state, event: event, message: message}
  end
end
