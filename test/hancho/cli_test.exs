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

    assert project.database_path == "/repo/.hancho/hancho.sqlite3"
  end
end
