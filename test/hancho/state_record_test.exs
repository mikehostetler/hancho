defmodule Hancho.StateRecordTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.{QueueRecord, RunRecord, StepRecord}

  test "upgrades legacy run and step records at the store boundary" do
    run = %{
      "id" => "legacy-run",
      "workflow_name" => "implement",
      "workflow_version" => 1,
      "workflow_source_path" => "implement.yaml",
      "workflow_yaml" => "name: implement",
      "workflow_sha256" => "abc",
      "status" => "running",
      "current_step" => "agent_call",
      "input_json" => "{}",
      "started_at" => "2026-08-17T00:00:00Z",
      "finished_at" => nil,
      "error_json" => nil
    }

    step = %{
      "position" => 0,
      "name" => "agent_call",
      "action" => "Hancho.Actions.Implement",
      "status" => "running",
      "params_json" => "{}",
      "result_json" => nil,
      "started_at" => "2026-08-17T00:00:00Z",
      "finished_at" => nil,
      "error_json" => nil
    }

    assert {:ok, upgraded_run} = run |> RunRecord.upgrade() |> RunRecord.new()
    assert upgraded_run.record_version == 1
    assert upgraded_run.transition_version == 0

    assert {:ok, upgraded_step} = step |> StepRecord.upgrade() |> StepRecord.new()
    assert upgraded_step.operation_json == nil
    assert upgraded_step.repairs_json == "[]"
  end

  test "removes legacy queue phases" do
    queue = %{
      "id" => "legacy-queue",
      "workflow_name" => "implement",
      "source" => "beadwork-ready",
      "status" => "stopped",
      "repository" => "/repo",
      "expected_branch" => "main",
      "expected_head" => "abc",
      "expected_worktrees" => [],
      "current_position" => 0,
      "current_run_id" => "legacy-queue-001",
      "items" => [
        %{
          "position" => 0,
          "issue_id" => "task-1",
          "run_id" => "legacy-queue-001",
          "status" => "stopped",
          "error" => "interrupted"
        }
      ],
      "started_at" => "2026-08-17T00:00:00Z",
      "finished_at" => "2026-08-17T00:01:00Z",
      "error" => "interrupted"
    }

    assert {:ok, upgraded} = queue |> QueueRecord.upgrade() |> QueueRecord.new()
    assert upgraded.record_version == 2
    refute Map.has_key?(Map.from_struct(hd(upgraded.items)), :phase)
  end
end
