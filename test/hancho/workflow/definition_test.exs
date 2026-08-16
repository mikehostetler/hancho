defmodule Hancho.Workflow.DefinitionTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.{Definition, Station, Transition}

  test "rejects duplicate states, stations, and transitions" do
    assert {:error, errors} =
             Definition.new(
               name: "invalid",
               version: 1,
               initial_state: "one",
               terminal_states: ["two"],
               states: ["one", "two", "two"],
               stations: [
                 %Station{id: "work", capability: "read"},
                 %Station{id: "work", capability: "review"}
               ],
               transitions: [
                 %Transition{from: "one", event: "go", to: "two"},
                 %Transition{from: "one", event: "go", to: "two"}
               ]
             )

    assert Enum.any?(errors, &String.contains?(&1, "duplicate state"))
    assert Enum.any?(errors, &String.contains?(&1, "duplicate station"))
    assert Enum.any?(errors, &String.contains?(&1, "duplicate transition"))
  end

  test "finds unknown and unreachable state references" do
    assert {:error, errors} =
             Definition.new(
               name: "invalid",
               version: 1,
               initial_state: "one",
               terminal_states: ["missing"],
               states: ["one", "two", "orphan"],
               stations: [],
               transitions: [%Transition{from: "one", event: "go", to: "two"}]
             )

    assert "terminal state 'missing' is unknown" in errors
    assert "state 'orphan' is unreachable" in errors
  end

  test "rejects an action with an unknown station" do
    assert {:error, errors} =
             Definition.new(
               name: "invalid",
               version: 1,
               initial_state: "one",
               terminal_states: ["two"],
               states: ["one", "two"],
               stations: [],
               transitions: [
                 %Transition{from: "one", event: "go", to: "two", actions: [%{station: "absent"}]}
               ]
             )

    assert "action uses unknown station 'absent'" in errors
  end
end
