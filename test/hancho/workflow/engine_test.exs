defmodule Hancho.Workflow.EngineTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.{Definition, Engine, Event, Transition}

  test "returns the same transition for the same input" do
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()

    first = Engine.transition(definition, "released", "start", %{})
    second = Engine.transition(definition, "released", "start", %{})

    assert first == second
    assert {:ok, %{state: "operating", actions: [%{station: "operate"}]}} = first
  end

  test "rejects invalid and stale events without a state change" do
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()

    assert {:error, invalid} = Engine.transition(definition, "released", "harness_succeeded")
    assert invalid.code == :invalid_event
    assert invalid.state == "released"

    event = %Event{name: "start", expected_state: "operating"}
    assert {:error, stale} = Engine.transition(definition, "released", event)
    assert stale.code == :stale_event
  end

  test "checks facts, artifacts, decisions, and authority" do
    definition =
      Definition.new!(
        name: "guarded",
        version: 1,
        initial_state: "ready",
        terminal_states: ["done"],
        states: ["ready", "done"],
        stations: [],
        transitions: [
          %Transition{
            from: "ready",
            event: "accept",
            to: "done",
            guards: [
              {:fact, "checks_passed"},
              {:artifact, "receipt"},
              {:decision, "merge"},
              {:authority, "merge_authority"}
            ]
          }
        ]
      )

    assert {:error, rejection} = Engine.transition(definition, "ready", "accept", %{})
    assert length(rejection.missing) == 4

    facts = %{
      facts: %{"checks_passed" => true},
      artifacts: ["receipt"],
      decisions: %{"merge" => "approved"},
      authorities: ["merge_authority"]
    }

    assert {:ok, %{state: "done", terminal: true}} =
             Engine.transition(definition, "ready", "accept", facts)
  end

  test "covers every declared walking-skeleton transition and rejects other pairs" do
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    events = definition.transitions |> Enum.map(& &1.event) |> Enum.uniq()

    for state <- definition.states, event <- events do
      declared? = Enum.any?(definition.transitions, &(&1.from == state and &1.event == event))

      if declared? do
        assert {:ok, _result} = Engine.transition(definition, state, event)
      else
        assert {:error, %{code: :invalid_event}} = Engine.transition(definition, state, event)
      end
    end
  end
end
