defmodule Hancho.Workflows.Plan.V1 do
  @moduledoc false
  @behaviour Hancho.Workflow

  alias Hancho.Workflow.{Definition, Station, Transition}

  @impl true
  def definition do
    Definition.new!(
      name: "plan",
      version: 1,
      initial_state: "released",
      terminal_states: ["complete", "stopped", "cancelled"],
      states: [
        "released",
        "researching",
        "drafting",
        "reviewing",
        "awaiting_approval",
        "complete",
        "stopped",
        "cancelled"
      ],
      stations: [
        %Station{
          id: "research",
          capability: "read",
          authority: "read_only",
          evidence: ["research_notes"]
        },
        %Station{id: "draft", capability: "read", authority: "artifact_only", evidence: ["plan"]},
        %Station{
          id: "review",
          capability: "review",
          authority: "read_only",
          evidence: ["plan", "review"]
        }
      ],
      transitions: [
        %Transition{
          from: "released",
          event: "start",
          to: "researching",
          actions: [%{type: "run_harness", station: "research"}]
        },
        %Transition{
          from: "researching",
          event: "research_complete",
          to: "drafting",
          actions: [%{type: "run_harness", station: "draft"}]
        },
        %Transition{
          from: "drafting",
          event: "draft_complete",
          to: "reviewing",
          guards: [{:artifact, "plan"}],
          actions: [%{type: "run_harness", station: "review"}]
        },
        %Transition{
          from: "reviewing",
          event: "review_rework",
          to: "drafting",
          actions: [%{type: "run_harness", station: "draft"}]
        },
        %Transition{
          from: "reviewing",
          event: "review_accepted",
          to: "awaiting_approval",
          guards: [{:artifact, "plan"}]
        },
        %Transition{
          from: "awaiting_approval",
          event: "approved",
          to: "complete",
          guards: [{:decision, "plan_approval"}, {:artifact, "plan"}]
        },
        %Transition{from: "awaiting_approval", event: "rejected", to: "stopped"},
        %Transition{from: "researching", event: "andon", to: "stopped"},
        %Transition{from: "drafting", event: "andon", to: "stopped"},
        %Transition{from: "reviewing", event: "andon", to: "stopped"},
        %Transition{from: "released", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "researching", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "drafting", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "reviewing", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "awaiting_approval", event: "cancel_requested", to: "cancelled"}
      ]
    )
  end
end
