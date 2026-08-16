defmodule Hancho.Workflows.WalkingSkeleton.V1 do
  @moduledoc false
  @behaviour Hancho.Workflow

  alias Hancho.Workflow.{Definition, Station, Transition}

  @impl true
  def definition do
    Definition.new!(
      name: "walking_skeleton",
      version: 1,
      initial_state: "released",
      terminal_states: ["complete", "stopped", "cancelled"],
      states: ["released", "operating", "complete", "stopped", "cancelled"],
      stations: [
        %Station{
          id: "operate",
          capability: "read",
          authority: "read_only",
          evidence: ["harness_result"]
        }
      ],
      transitions: [
        %Transition{
          from: "released",
          event: "start",
          to: "operating",
          actions: [%{type: "run_harness", station: "operate"}]
        },
        %Transition{from: "operating", event: "harness_succeeded", to: "complete"},
        %Transition{from: "operating", event: "harness_failed", to: "stopped"},
        %Transition{
          from: "stopped",
          event: "resume_requested",
          to: "operating",
          actions: [%{type: "run_harness", station: "operate"}]
        },
        %Transition{from: "released", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "operating", event: "cancel_requested", to: "cancelled"}
      ]
    )
  end
end
