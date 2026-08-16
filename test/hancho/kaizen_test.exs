defmodule Hancho.KaizenTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Workflow.Registry
  alias Hancho.{Config, Journal, Kaizen, Operations, Repository, SQLite, Store}

  test "keeps a versioned proposal pending until approval and records a later evaluation" do
    root = temporary_git_repository!("kaizen")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    {:ok, definition} = Registry.fetch("walking_skeleton")
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "kaizen-work")

    {:ok, decision} =
      Journal.request_decision(repository, work_order["id"], "standard_work_change", %{
        proposal_id: "proposal-1",
        version: 1,
        proposal: "Run the narrow check first.",
        expected_result: "Reduce rework."
      })

    assert :ok =
             SQLite.execute(
               Store.path(repository),
               "INSERT INTO standard_work_proposals (id, run_id, version, proposal, expected_result, status, approval_decision_id, created_at) VALUES ('proposal-1', '#{work_order["id"]}', 1, 'Run the narrow check first.', 'Reduce rework.', 'proposed', '#{decision["id"]}', '2026-01-01T00:00:00Z');"
             )

    assert {:error, %{code: :kaizen_not_approved}} =
             Kaizen.evaluate(repository, "proposal-1", "Rework fell by one cycle.")

    assert {:ok, _} =
             Operations.decide(
               repository,
               decision["id"],
               "approved",
               "operator",
               "Use this standard work for the next version."
             )

    assert {:ok, evaluated} =
             Kaizen.evaluate(repository, "proposal-1", "Rework fell by one cycle.")

    assert evaluated["version"] == 1
    assert evaluated["status"] == "evaluated"
    assert evaluated["proposal"] == "Run the narrow check first."
    assert evaluated["expected_result"] == "Reduce rework."

    evaluation = Hancho.JSON.decode!(evaluated["evaluation_json"])
    assert evaluation["actual_result"] == "Rework fell by one cycle."
    assert evaluation["evaluated_at"]
  end
end
