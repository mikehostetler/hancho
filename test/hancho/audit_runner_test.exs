defmodule Hancho.AuditRunnerTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{AuditRunner, Repository}

  setup do
    root = temporary_git_repository!("audit")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "lib/sample.ex"), "defmodule Sample, do: :ok\n")
    File.write!(Path.join(root, "test/sample_test.exs"), "# fixture\n")
    {_output, 0} = System.cmd("git", ["-C", root, "add", "."])
    {_output, 0} = System.cmd("git", ["-C", root, "commit", "-q", "-m", "Add audit fixture"])
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    %{root: root, repository: repository}
  end

  test "runs bounded units, removes weak duplicates, and leaves Git unchanged", context do
    before = git_snapshot(context.root)

    findings = [
      %{
        title: "Shared state",
        evidence: "lib/sample.ex:1",
        priority: "high",
        scope: "lib",
        material: true
      },
      %{
        title: "Shared state",
        evidence: "lib/sample.ex:1",
        priority: "high",
        scope: "lib",
        material: true
      },
      %{title: "Style", evidence: "", priority: "low", scope: "test", material: false}
    ]

    assert {:ok, outcome} =
             AuditRunner.run(context.repository, "audit-1",
               audit_scopes: ["README.md", "lib", "test"],
               findings: findings,
               skip_decisions: ["No dependency audit: no dependency manifest in admitted scope."]
             )

    assert outcome.work_order["state"] == "complete"
    assert length(outcome.inspections) == 3
    assert Enum.all?(outcome.inspections, &is_binary(&1.harness_session))
    assert length(outcome.findings) == 1
    assert outcome.coverage.complete
    assert git_snapshot(context.root) == before

    report =
      File.read!(Path.join(context.repository.runtime_dir, outcome.report["relative_path"]))

    assert report =~ "Canonical method"
    assert report =~ "HIGH"
    assert report =~ "Explicit skip decisions"
  end

  test "retains failed unit evidence and reports missing coverage", context do
    before = git_snapshot(context.root)

    assert {:ok, outcome} =
             AuditRunner.run(context.repository, "audit-2",
               audit_scopes: ["lib", "test"],
               failed_units: ["test"]
             )

    assert Enum.find(outcome.inspections, &(&1.scope == "lib")).status == "complete"
    assert Enum.find(outcome.inspections, &(&1.scope == "test")).status == "failed"
    assert outcome.coverage.missing == ["test"]
    assert Enum.any?(outcome.findings, &(&1.priority == "high" and &1.scope == "test"))
    assert git_snapshot(context.root) == before
  end

  test "rejects overlapping ownership without a recorded reason", context do
    assert {:error, %{code: :audit_scope_overlap}} =
             AuditRunner.run(context.repository, "audit-3", audit_scopes: ["lib", "lib/nested"])
  end

  defp git_snapshot(root) do
    {head, 0} = System.cmd("git", ["-C", root, "rev-parse", "HEAD"])

    {status, 0} =
      System.cmd("git", ["-C", root, "status", "--porcelain=v1", "--untracked-files=all"])

    {String.trim(head), status}
  end
end
