defmodule Hancho.ForensicsTest do
  use ExUnit.Case, async: false

  alias Hancho.Forensics
  alias Hancho.Workflow.Result

  test "writes a private workflow failure report with Git state and cleanup evidence" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    File.write!(Path.join(repository, "agent-change.txt"), "retained source\n")

    assert {:ok, result} =
             Result.new(%{
               run_id: "run-failed",
               workflow: "implement_in_place",
               status: :stopped,
               current_step: "validate_scope",
               outputs: %{},
               artifacts: %{
                 "workspace_opened" => %{
                   "mode" => "in_place",
                   "workspace_path" => repository,
                   "baseline" => "abc123"
                 }
               },
               error: %{
                 code: "changes_outside_allowed_scope",
                 unexpected_paths: ["agent-change.txt"]
               },
               cleanup: %{
                 status: "completed",
                 removed: ["_build", "deps"],
                 reclaimed_bytes: 42
               }
             })

    assert {:ok, path} = Forensics.capture_run(project, result)
    assert path == Path.join(project.forensics_path, "runs/run-failed.json")
    assert private_mode?(path, 0o600)
    assert private_mode?(Path.dirname(path), 0o700)

    report = path |> File.read!() |> Jason.decode!()
    assert report["schema_version"] == 1
    assert report["kind"] == "workflow_failure"
    assert report["run"]["current_step"] == "validate_scope"
    assert report["run"]["error"]["code"] == "changes_outside_allowed_scope"
    assert report["repository"]["clean"] == false

    assert report["repository"]["status"] == [
             %{"index" => "?", "working_tree" => "?", "path" => "agent-change.txt"}
           ]

    assert report["workspace"]["mode"] == "in_place"
    assert report["cleanup"]["removed"] == ["_build", "deps"]
  end

  test "writes a queue report that keeps workflow and reconciliation errors" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)

    error = %{
      code: "workflow_stopped",
      step: "validate_scope",
      error: %{code: "changes_outside_allowed_scope"},
      reconciliation: %{
        status: "failed",
        error: %{code: "filesystem_out_of_sync", field: "repository_status"}
      }
    }

    assert {:ok, path} =
             Forensics.capture_queue(project, %{
               queue_id: "queue-failed",
               workflow: "implement_in_place",
               issue_id: "task-1",
               child_run_id: "queue-failed-001",
               position: 0,
               total_count: 1,
               error: error,
               child_forensic_report: "/repo/.hancho/forensics/runs/queue-failed-001.json"
             })

    report = path |> File.read!() |> Jason.decode!()
    assert report["kind"] == "queue_failure"
    assert report["queue"]["error"]["code"] == "workflow_stopped"

    assert report["queue"]["error"]["reconciliation"]["error"]["code"] ==
             "filesystem_out_of_sync"

    assert report["child_forensic_report"] ==
             "/repo/.hancho/forensics/runs/queue-failed-001.json"
  end

  defp private_mode?(path, expected) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777) == expected
  end

  defp temporary_repository do
    path = Path.join(System.tmp_dir!(), "hancho-forensics-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)

    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")
    {_output, 0} = System.cmd("git", ["-C", path, "add", ".gitignore"])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "commit",
        "-m",
        "chore: initialize repository"
      ])

    path
  end
end
