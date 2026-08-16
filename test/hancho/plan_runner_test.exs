defmodule Hancho.PlanRunnerTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Artifacts, InstructionPacks, Journal, Operations, PlanRunner, Repository}

  setup do
    root = temporary_git_repository!("plan")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    %{root: root, repository: repository}
  end

  test "produces a bounded read-only plan and approves its exact hash", context do
    before = git_snapshot(context.root)

    assert {:ok, outcome} =
             PlanRunner.run(context.repository, "issue-10",
               goal: "Add a safe feature",
               scope: ["lib/feature.ex"],
               dependencies: ["Elixir runtime"],
               risks: ["Public API change"],
               checks: ["mix test"],
               acceptance: ["Tests pass"]
             )

    assert outcome.work_order["state"] == "awaiting_approval"
    assert outcome.decision["status"] == "pending"
    request = Hancho.JSON.decode!(outcome.decision["request_json"])
    assert request["artifact_hash"] == outcome.plan["content_hash"]

    markdown =
      File.read!(Path.join(context.repository.runtime_dir, outcome.plan["relative_path"]))

    for heading <- ~w(Goal Scope Tasks Dependencies Risks Checks Acceptance),
        do: assert(markdown =~ heading)

    assert git_snapshot(context.root) == before

    assert {:ok, uses} = InstructionPacks.uses(context.repository, outcome.work_order["id"])
    assert Enum.any?(uses, &(&1["name"] == "compound_brainstorm"))
    assert Enum.any?(uses, &(&1["name"] == "matt_pocock" and &1["status"] == "setup_required"))

    assert {:ok, _decision} =
             Operations.decide(
               context.repository,
               outcome.decision["id"],
               "approved",
               "owner",
               "I approve this exact plan."
             )

    assert {:ok, completed} = PlanRunner.resume(context.repository, outcome.work_order["id"])
    assert completed.work_order["state"] == "complete"
    assert git_snapshot(context.root) == before
  end

  test "records review rework without source changes", context do
    before = git_snapshot(context.root)

    assert {:ok, outcome} =
             PlanRunner.run(context.repository, "issue-11",
               review_findings: ["Name the exact migration check."]
             )

    assert {:ok, events} = Journal.events(context.repository, outcome.work_order["id"])
    assert Enum.any?(events, &(&1["event"] == "review_rework"))
    assert {:ok, artifacts} = Artifacts.list(context.repository, outcome.work_order["id"])
    assert Enum.count(artifacts, &(&1["kind"] == "plan")) == 2
    assert git_snapshot(context.root) == before
  end

  defp git_snapshot(root) do
    {head, 0} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"])

    {status, 0} =
      System.cmd("git", ["-C", root, "status", "--porcelain=v1", "--untracked-files=all"])

    {String.trim(head), status}
  end
end
