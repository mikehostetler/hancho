defmodule Hancho.Workflows.Audit.V1 do
  @moduledoc false
  @behaviour Hancho.Workflow

  alias Hancho.Workflow.{Definition, Station, Transition}

  @impl true
  def definition do
    Definition.new!(
      name: "audit",
      version: 1,
      initial_state: "released",
      terminal_states: ["complete", "stopped", "cancelled"],
      states: [
        "released",
        "inventorying",
        "inspecting",
        "validating",
        "reporting",
        "complete",
        "stopped",
        "cancelled"
      ],
      stations: [
        %Station{
          id: "inventory",
          capability: "read",
          authority: "read_only",
          evidence: ["audit_inventory"]
        },
        %Station{
          id: "inspect",
          capability: "read",
          authority: "read_only",
          evidence: ["inspection_unit"]
        },
        %Station{
          id: "validate",
          capability: "review",
          authority: "read_only",
          evidence: ["audit_findings", "coverage"]
        }
      ],
      transitions: [
        %Transition{
          from: "released",
          event: "start",
          to: "inventorying",
          actions: [%{type: "run_harness", station: "inventory"}]
        },
        %Transition{
          from: "inventorying",
          event: "inventory_complete",
          to: "inspecting",
          guards: [{:artifact, "audit_inventory"}],
          actions: [%{type: "fan_out", station: "inspect"}]
        },
        %Transition{
          from: "inspecting",
          event: "inspection_complete",
          to: "validating",
          guards: [{:artifact, "inspection_unit"}],
          actions: [%{type: "run_harness", station: "validate"}]
        },
        %Transition{
          from: "validating",
          event: "validation_complete",
          to: "reporting",
          guards: [{:artifact, "audit_findings"}]
        },
        %Transition{
          from: "reporting",
          event: "report_complete",
          to: "complete",
          guards: [{:artifact, "audit_report"}]
        },
        %Transition{from: "inventorying", event: "andon", to: "stopped"},
        %Transition{from: "inspecting", event: "andon", to: "stopped"},
        %Transition{from: "validating", event: "andon", to: "stopped"},
        %Transition{from: "reporting", event: "andon", to: "stopped"},
        %Transition{from: "released", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "inventorying", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "inspecting", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "validating", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "reporting", event: "cancel_requested", to: "cancelled"}
      ]
    )
  end
end
