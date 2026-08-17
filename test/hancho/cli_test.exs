defmodule Hancho.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule ProjectAPI do
    def discover(cwd: cwd), do: {:ok, Hancho.Project.new(cwd)}
  end

  defmodule WorkflowRunner do
    def run(project, "implement", input, _options) do
      send(self(), {:workflow_input, project, input})

      Hancho.Workflow.Result.new(%{
        run_id: "run-123",
        workflow: "implement",
        status: :completed,
        current_step: nil,
        outputs: %{},
        error: nil
      })
    end

    def retry(project, "run-stopped", options) do
      send(self(), {:workflow_retry, project, options[:verbose]})

      Hancho.Workflow.Result.new(%{
        run_id: "run-stopped",
        workflow: "implement",
        status: :completed,
        current_step: nil,
        outputs: %{},
        error: nil
      })
    end
  end

  defmodule QueueRunner do
    def run(project, "implement", "beadwork-ready", 5, options) do
      send(self(), {:queue_input, project, options[:verbose]})
      options[:progress].("Queue queue-1 started.")

      Hancho.Workflow.QueueResult.new(%{
        queue_id: "queue-1",
        workflow: "implement",
        status: :completed,
        completed_count: 5,
        total_count: 5,
        current_issue: nil,
        child_runs: ["queue-1-001"],
        error: nil
      })
    end

    def preview(project, "implement", "beadwork-ready", 1, options) do
      send(self(), {:queue_preview, project, options[:verbose]})

      {:ok,
       %{
         workflow: "implement",
         source: "beadwork-ready",
         issues: [%{"id" => "task-1", "title" => "First task", "status" => "open"}],
         repository: %{branch: "main", head: "abc123", clean: true, worktrees: ["retained"]},
         settings: %{
           provider: "grok",
           implementation_timeout_ms: 1_800_000,
           verification_timeout_ms: 600_000
         }
       }}
    end

    def resume(project, "queue-stopped", options) do
      send(self(), {:queue_resume, project, options[:verbose]})
      options[:progress].("Queue queue-stopped resumed.")

      Hancho.Workflow.QueueResult.new(%{
        queue_id: "queue-stopped",
        workflow: "implement",
        status: :completed,
        completed_count: 1,
        total_count: 1,
        current_issue: nil,
        child_runs: ["queue-stopped-001"],
        error: nil
      })
    end
  end

  test "has explicit help and version commands" do
    assert capture_io(fn -> assert Hancho.CLI.run([]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["--help"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["-h"]) == 0 end) =~ "hancho doctor"
    assert capture_io(fn -> assert Hancho.CLI.run(["--version"]) == 0 end) == "0.1.0\n"
    assert capture_io(fn -> assert Hancho.CLI.run(["-v"]) == 0 end) == "0.1.0\n"
    assert capture_io(fn -> assert Hancho.CLI.run(["help"]) == 0 end) =~ "Usage:"
    assert capture_io(fn -> assert Hancho.CLI.run(["version"]) == 0 end) == "0.1.0\n"
  end

  test "parses global options after a command" do
    assert capture_io(fn -> assert Hancho.CLI.run(["doctor", "--help"]) == 0 end) =~ "Usage:"
  end

  test "rejects an unknown command" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: unknown\nRun 'hancho --help' for usage.\n"
  end

  test "rejects unknown options" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["--unknown"]) == 2 end)

    assert output ==
             "ERROR: Unknown option: --unknown\nRun 'hancho --help' for usage.\n"
  end

  test "rejects extra command arguments" do
    output = capture_io(:stderr, fn -> assert Hancho.CLI.run(["doctor", "extra"]) == 2 end)

    assert output ==
             "ERROR: Unknown command: doctor extra\nRun 'hancho --help' for usage.\n"
  end

  test "runs one workflow in the foreground" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["run", "implement", "hancho-123"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 workflow_runner: WorkflowRunner
               ) == 0
      end)

    assert output == "Workflow implement completed. Run: run-123\n"

    assert_received {:workflow_input, project,
                     %{"repo_path" => "/repo", "issue_id" => "hancho-123"}}

    assert project.bedrock_path == "/repo/.hancho/bedrock"
  end

  test "retries a stopped workflow" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["retry", "run-stopped", "--verbose"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 workflow_runner: WorkflowRunner
               ) == 0
      end)

    assert output == "Workflow implement completed. Run: run-stopped\n"
    assert_received {:workflow_retry, project, true}
    assert project.root == "/repo"
  end

  test "resumes a stopped queue" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["resume", "queue-stopped", "--verbose"],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: QueueRunner
               ) == 0
      end)

    assert output == "Queue queue-stopped resumed.\n"
    assert_received {:queue_resume, project, true}
    assert project.root == "/repo"
  end

  test "runs an explicit foreground queue with verbose progress" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 [
                   "queue",
                   "implement",
                   "--source",
                   "beadwork-ready",
                   "--count",
                   "5",
                   "--verbose"
                 ],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: QueueRunner
               ) == 0
      end)

    assert output == "Queue queue-1 started.\n"
    assert_received {:queue_input, project, true}
    assert project.root == "/repo"
  end

  test "requires explicit queue source and count" do
    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(["queue", "implement", "--source", "beadwork-ready"]) == 2
      end)

    assert output == "ERROR: queue requires --source and a positive --count.\n"
  end

  test "previews a queue without running it" do
    output =
      capture_io(fn ->
        assert Hancho.CLI.run(
                 [
                   "queue",
                   "implement",
                   "--source",
                   "beadwork-ready",
                   "--count",
                   "1",
                   "--dry-run"
                 ],
                 cwd: "/repo",
                 project_api: ProjectAPI,
                 queue_runner: QueueRunner
               ) == 0
      end)

    assert output ==
             "Dry run: implement selected 1 task from beadwork-ready.\n" <>
               "Repository: main at abc123 (clean)\n" <>
               "Retained worktrees: 1\n" <>
               "Provider: grok\n" <>
               "Timeouts: implement 1800000 ms, verify 600000 ms\n" <>
               "1. task-1 — First task\n"

    assert_received {:queue_preview, project, false}
    assert project.root == "/repo"
    refute_received {:queue_input, _project, _verbose}
  end
end
