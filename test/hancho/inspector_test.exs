defmodule Hancho.InspectorTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.Inspector

  defmodule Store do
    def open(_path), do: {:ok, :memory}
    def close(:memory), do: :ok

    def fetch_run(:memory, "run-inspect") do
      outputs = %{
        "workspace_opened" => %{"worktree_path" => "/repo/.hancho/worktrees/run-inspect"},
        "agent_call" => %{
          "provider" => "grok",
          "harness_run_id" => "harness-1",
          "status" => "completed",
          "text" => "implemented"
        },
        "test_suite" => %{
          "exit_status" => 0,
          "output" => "Finished in 1 second\nResult: 12 passed\n",
          "output_path" => "/repo/.hancho/logs/run-inspect-verify.log"
        },
        "saved_change" => %{"commit" => "abc123"}
      }

      {:ok,
       %{
         "id" => "run-inspect",
         "workflow_name" => "implement",
         "status" => "stopped",
         "current_step" => "publish",
         "started_at" => "2026-08-17T10:00:00Z",
         "finished_at" => "2026-08-17T10:02:00Z",
         "error_json" => Jason.encode!(%{"message" => "branch changed"}),
         "outputs_json" => Jason.encode!(outputs)
       }}
    end

    def list_steps(:memory, "run-inspect") do
      {:ok,
       [
         step(0, "workspace_opened", "completed", "2026-08-17T10:00:00Z", "2026-08-17T10:00:10Z"),
         step(1, "agent_call", "completed", "2026-08-17T10:00:10Z", "2026-08-17T10:01:30Z"),
         step(2, "test_suite", "completed", "2026-08-17T10:01:30Z", "2026-08-17T10:01:45Z"),
         step(3, "saved_change", "completed", "2026-08-17T10:01:45Z", "2026-08-17T10:01:45Z"),
         step(4, "publish", "stopped", "2026-08-17T10:01:45Z", "2026-08-17T10:02:00Z")
       ]}
    end

    defp step(position, name, status, started_at, finished_at) do
      %{
        "position" => position,
        "name" => name,
        "action" => action(name),
        "status" => status,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "error_json" => if(status == "stopped", do: Jason.encode!("branch changed"), else: nil)
      }
    end

    defp action("workspace_opened"), do: "Hancho.Actions.CreateWorktree"
    defp action("agent_call"), do: "Hancho.Actions.Implement"
    defp action("test_suite"), do: "Hancho.Actions.Verify"
    defp action("saved_change"), do: "Hancho.Actions.Commit"
    defp action("publish"), do: "Hancho.Actions.Land"
  end

  test "reports durable timings, agent output, verification, and retained work" do
    project = Hancho.Project.new("/repo")

    assert {:ok, report} = Inspector.inspect(project, "run-inspect", store_api: Store)
    assert report.status == "stopped"
    assert report.current_step == "publish"
    assert report.duration_ms == 120_000
    assert report.provider["provider"] == "grok"
    assert report.provider["harness_run_id"] == "harness-1"
    assert report.verification.summary == "Result: 12 passed"
    assert report.verification.exit_status == 0
    assert report.commit == "abc123"
    assert report.retained_worktree == "/repo/.hancho/worktrees/run-inspect"
    assert report.forensic_report == nil
    assert report.failure == %{"message" => "branch changed"}
    assert Enum.map(report.steps, & &1.duration_ms) == [10_000, 80_000, 15_000, 0, 15_000]
    assert List.last(report.steps).error == "branch changed"
  end
end
