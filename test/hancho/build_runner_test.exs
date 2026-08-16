defmodule Hancho.BuildRunnerTest do
  use Hancho.RepositoryCase, async: true

  @moduletag :integration

  alias Hancho.{BuildRunner, Config, Git, Journal, JSON, ReadModel, Repository}

  test "creates an exact reviewed candidate without changing the target branch" do
    {root, repository} = initialized_project!(:success)
    {:ok, baseline} = Git.command(root, ["rev-parse", "HEAD"])

    assert {:ok, outcome} =
             BuildRunner.run(repository, "build-1",
               work_spec: Hancho.BuildFixture.spec("build-1")
             )

    assert outcome.work_order["state"] == "candidate_ready"
    assert outcome.work_order["status"] == "complete"
    assert {:ok, ^baseline} = Git.command(root, ["rev-parse", "HEAD"])

    assert {:ok, candidate} =
             Git.command(root, ["rev-parse", "refs/hancho/candidates/#{outcome.work_order["id"]}"])

    assert candidate == outcome.candidate_commit
    refute File.exists?(outcome.work_order["worktree_path"])

    assert {:ok, commit_message} = Git.command(root, ["show", "-s", "--format=%B", candidate])
    assert commit_message =~ "Hancho-Work-Order: #{outcome.work_order["id"]}"
    assert commit_message =~ "Hancho-Work-Reference: build-1"

    receipt_path = Path.join(repository.runtime_dir, outcome.receipt["relative_path"])
    receipt = JSON.decode!(File.read!(receipt_path))
    assert receipt["candidate_commit"] == candidate
    assert receipt["baseline_commit"] == baseline
    assert receipt["changed_paths"] == ["lib/added.ex"]
    assert length(receipt["precommit_checks"]["checks"]) == 3
    assert length(receipt["postcommit_checks"]["checks"]) == 3
  end

  test "stops and keeps the worktree after an out-of-scope change" do
    {_root, repository} = initialized_project!(:scope_violation)

    assert {:ok, outcome} =
             BuildRunner.run(repository, "build-2",
               work_spec: Hancho.BuildFixture.spec("build-2")
             )

    assert outcome.work_order["state"] == "stopped"
    assert outcome.error.code == :scope_violation
    assert File.dir?(outcome.worktree)
  end

  test "stops when the harness creates a commit" do
    {_root, repository} = initialized_project!(:commit)

    assert {:ok, outcome} =
             BuildRunner.run(repository, "build-3",
               work_spec: Hancho.BuildFixture.spec("build-3")
             )

    assert outcome.work_order["state"] == "stopped"
    assert outcome.error.code == :harness_git_effect
  end

  test "requests a dependency decision before it verifies mix.exs" do
    {_root, repository} = initialized_project!(:gate)

    assert {:ok, outcome} =
             BuildRunner.run(repository, "build-4",
               work_spec: Hancho.BuildFixture.spec("build-4", ["mix.exs"])
             )

    assert outcome.error.code == :gate_required
    assert {:ok, [decision]} = Journal.open_decisions(repository)
    assert decision["kind"] == "dependency"

    assert {:ok, shown} = ReadModel.show(repository, outcome.work_order["id"])
    assert shown.next_action =~ "hancho approve"

    assert {:ok, approved} =
             Hancho.Operations.decide(
               repository,
               decision["id"],
               "approved",
               "owner",
               "Dependency metadata reviewed"
             )

    assert approved["status"] == "approved"
    assert {:ok, resumed} = Hancho.Operations.resume(repository, outcome.work_order["id"])
    assert resumed.work_order["state"] == "candidate_ready"
  end

  test "runs a bounded repair and uses a fresh harness session" do
    {_root, repository} = initialized_project!(:repair)

    assert {:ok, outcome} =
             BuildRunner.run(repository, "build-5",
               work_spec:
                 Hancho.BuildFixture.spec("build-5")
                 |> Map.put("checks", [
                   ["sh", "-c", "! grep -q 'this is invalid' lib/added.ex"]
                 ])
             )

    assert outcome.work_order["state"] == "candidate_ready"
    assert {:ok, shown} = ReadModel.show(repository, outcome.work_order["id"])
    assert Enum.count(shown.harness_sessions, &(&1["station"] == "repair")) == 1

    assert Enum.uniq(Enum.map(shown.harness_sessions, & &1["id"])) |> length() ==
             length(shown.harness_sessions)
  end

  test "stops if review changes the candidate" do
    {_root, repository} = initialized_project!(:review_edit)

    assert {:ok, outcome} =
             BuildRunner.run(repository, "build-6",
               work_spec: Hancho.BuildFixture.spec("build-6")
             )

    assert outcome.work_order["state"] == "stopped"
    assert outcome.error.code == :review_changed_candidate
  end

  test "stops when the target branch changes during implementation" do
    {root, repository} = initialized_project!(:target_change)
    assert {:ok, before} = Git.command(root, ["rev-parse", "HEAD"])

    assert {:ok, outcome} =
             BuildRunner.run(repository, "build-7",
               work_spec: Hancho.BuildFixture.spec("build-7")
             )

    assert outcome.work_order["state"] == "stopped"
    assert outcome.error.code == :harness_git_effect or outcome.error.code == :git_failed
    assert {:ok, after_commit} = Git.command(root, ["rev-parse", "HEAD"])
    refute after_commit == before
  end

  test "builds a private Phoenix-shaped application with the Phoenix profile" do
    root = Hancho.BuildFixture.phoenix_project!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    Hancho.BuildFixture.configure_adapter!(root, :success)
    {:ok, repository} = Repository.discover(root)

    spec =
      Hancho.BuildFixture.spec("phoenix-build")
      |> Map.put("profile", "phoenix_private")
      |> Map.delete("checks")

    assert {:ok, outcome} = BuildRunner.run(repository, "phoenix-build", work_spec: spec)
    assert outcome.work_order["state"] == "candidate_ready"
  end

  test "requires human acceptance of the exact reviewed candidate when configured" do
    {_root, repository} = initialized_project!(:success)

    spec =
      Hancho.BuildFixture.spec("build-human")
      |> Map.put("required_gates", ["candidate_acceptance"])

    assert {:ok, waiting} =
             BuildRunner.run(repository, "build-human", work_spec: spec)

    assert waiting.work_order["state"] == "awaiting_acceptance"
    assert File.dir?(waiting.work_order["worktree_path"])
    assert {:ok, [decision]} = Journal.open_decisions(repository)
    request = JSON.decode!(decision["request_json"])
    assert request["candidate_commit"] == waiting.candidate_commit
    assert request["receipt_hash"] == waiting.receipt["content_hash"]

    assert {:ok, _} =
             Hancho.Operations.decide(
               repository,
               decision["id"],
               "approved",
               "owner",
               "I approve this exact candidate and receipt."
             )

    assert {:ok, completed} = Hancho.Operations.resume(repository, waiting.work_order["id"])
    assert completed.work_order["state"] == "candidate_ready"
    refute File.exists?(waiting.work_order["worktree_path"])
  end

  test "rejects a gate approval after the worktree revision changes" do
    {_root, repository} = initialized_project!(:gate)

    assert {:ok, stopped} =
             BuildRunner.run(repository, "build-stale-gate",
               work_spec: Hancho.BuildFixture.spec("build-stale-gate", ["mix.exs"])
             )

    assert {:ok, [decision]} = Journal.open_decisions(repository)

    assert {:ok, _} =
             Hancho.Operations.decide(
               repository,
               decision["id"],
               "approved",
               "owner",
               "I approve the recorded worktree fingerprint."
             )

    File.write!(
      Path.join(stopped.worktree, "mix.exs"),
      File.read!(Path.join(stopped.worktree, "mix.exs")) <> "\n# changed after approval\n"
    )

    assert {:ok, still_stopped} = Hancho.Operations.resume(repository, stopped.work_order["id"])
    assert still_stopped.work_order["state"] == "stopped"
    assert still_stopped.error.code == :gate_required
    assert {:ok, [new_decision]} = Journal.open_decisions(repository)
    refute new_decision["id"] == decision["id"]
  end

  test "can require the review harness to differ from the implementation harness" do
    {_root, repository} = initialized_project!(:success)
    config_path = Repository.config_path(repository)

    File.write!(
      config_path,
      String.replace(
        File.read!(config_path),
        "require_independent_harness = false",
        "require_independent_harness = true"
      )
    )

    assert {:ok, stopped} =
             BuildRunner.run(repository, "build-independent",
               work_spec: Hancho.BuildFixture.spec("build-independent")
             )

    assert stopped.work_order["state"] == "stopped"
    assert stopped.error.code == :independent_reviewer_required
  end

  defp initialized_project!(mode) do
    root = Hancho.BuildFixture.project!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    Hancho.BuildFixture.configure_adapter!(root, mode)
    {:ok, repository} = Repository.discover(root)
    {:ok, _config} = Config.load(repository)
    {root, repository}
  end
end
