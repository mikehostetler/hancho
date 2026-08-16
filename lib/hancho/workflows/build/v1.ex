defmodule Hancho.Workflows.Build.V1 do
  @moduledoc false
  @behaviour Hancho.Workflow

  alias Hancho.Workflow.{Definition, Station, Transition}

  @impl true
  def definition do
    Definition.new!(
      name: "build",
      version: 1,
      initial_state: "released",
      terminal_states: ["candidate_ready", "stopped", "cancelled"],
      states: [
        "released",
        "implementing",
        "verifying",
        "repairing",
        "reviewing",
        "awaiting_acceptance",
        "candidate_ready",
        "stopped",
        "cancelled"
      ],
      stations: [
        %Station{
          id: "implement",
          capability: "edit_worktree",
          authority: "bounded_edit",
          evidence: ["worktree_diff"]
        },
        %Station{
          id: "repair",
          capability: "edit_worktree",
          authority: "bounded_edit",
          evidence: ["check_result"]
        },
        %Station{
          id: "review",
          capability: "review",
          authority: "read_only",
          evidence: ["candidate_commit", "check_result"]
        }
      ],
      transitions: [
        %Transition{
          from: "released",
          event: "start",
          to: "implementing",
          actions: [%{type: "run_harness", station: "implement"}]
        },
        %Transition{
          from: "implementing",
          event: "implementation_ready",
          to: "verifying",
          actions: [%{type: "verify_candidate"}]
        },
        %Transition{
          from: "verifying",
          event: "checks_failed",
          to: "repairing",
          actions: [%{type: "run_harness", station: "repair"}]
        },
        %Transition{
          from: "repairing",
          event: "repair_ready",
          to: "verifying",
          actions: [%{type: "verify_candidate"}]
        },
        %Transition{
          from: "verifying",
          event: "checks_passed",
          to: "reviewing",
          guards: [{:artifact, "check_result"}],
          actions: [%{type: "run_harness", station: "review"}]
        },
        %Transition{
          from: "reviewing",
          event: "review_accepted",
          to: "candidate_ready",
          guards: [{:artifact, "candidate_receipt"}]
        },
        %Transition{
          from: "reviewing",
          event: "review_recommended",
          to: "awaiting_acceptance",
          guards: [{:artifact, "candidate_receipt"}]
        },
        %Transition{
          from: "awaiting_acceptance",
          event: "candidate_approved",
          to: "candidate_ready",
          guards: [
            {:artifact, "candidate_receipt"},
            {:decision, "candidate_acceptance"}
          ]
        },
        %Transition{
          from: "awaiting_acceptance",
          event: "candidate_rejected",
          to: "stopped"
        },
        %Transition{
          from: "reviewing",
          event: "review_rework",
          to: "repairing",
          actions: [%{type: "run_harness", station: "repair"}]
        },
        %Transition{from: "implementing", event: "andon", to: "stopped"},
        %Transition{from: "verifying", event: "andon", to: "stopped"},
        %Transition{from: "repairing", event: "andon", to: "stopped"},
        %Transition{from: "reviewing", event: "andon", to: "stopped"},
        %Transition{from: "awaiting_acceptance", event: "andon", to: "stopped"},
        %Transition{
          from: "stopped",
          event: "resume_requested",
          to: "implementing"
        },
        %Transition{from: "released", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "implementing", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "verifying", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "repairing", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "reviewing", event: "cancel_requested", to: "cancelled"},
        %Transition{from: "awaiting_acceptance", event: "cancel_requested", to: "cancelled"}
      ]
    )
  end
end
