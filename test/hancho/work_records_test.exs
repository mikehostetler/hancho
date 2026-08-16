defmodule Hancho.WorkRecordsTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Config, Journal, Repository, WorkRecords}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "record-work")
    %{repository: repository, run_id: work_order["id"]}
  end

  test "stores one canonical commitment and execution reference", context do
    assert :ok =
             WorkRecords.link(context.repository, context.run_id,
               github_issue: "https://github.com/example/project/issues/10",
               beadwork: "bw-a123",
               metadata: %{accepted: true}
             )

    assert {:ok, references} = WorkRecords.list(context.repository, context.run_id)
    assert Enum.map(references, & &1["kind"]) == ["beadwork", "github_issue"]
  end

  test "requires at least one external reference", context do
    assert {:error, %{code: :work_reference_required}} =
             WorkRecords.link(context.repository, context.run_id, [])
  end

  test "classifies and records discovered work without expanding scope", context do
    assert WorkRecords.classify_discovery(%{title: "Small note"}) == "small_internal"

    assert WorkRecords.classify_discovery(%{title: "New commitment", customer_commit: true}) ==
             "decision_required"

    assert {:ok, small} =
             WorkRecords.record_discovery(
               context.repository,
               context.run_id,
               "review",
               %{title: "Small cleanup", evidence: %{path: "lib/one.ex"}}
             )

    assert small["status"] == "recorded"

    assert {:ok, material} =
             WorkRecords.record_discovery(
               context.repository,
               context.run_id,
               "review",
               %{title: "Cross repository change", cross_repository: true}
             )

    assert material["status"] == "pending_decision"
    assert is_binary(material["decision_id"])
    assert {:ok, [decision]} = Journal.open_decisions(context.repository)
    assert decision["kind"] == "discovered_scope"
  end
end
