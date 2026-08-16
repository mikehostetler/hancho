defmodule Hancho.PublicationDeliveryTest do
  use Hancho.RepositoryCase, async: false

  alias Hancho.Delivery.Request

  alias Hancho.{
    Closure,
    Delivery,
    Journal,
    Merge,
    Operations,
    Publication,
    PullRequest,
    WorkRecords
  }

  setup do
    root = temporary_git_repository!("effects")
    fixture = Hancho.EffectFixture.candidate_work_order!(root)
    remote = Hancho.EffectFixture.bare_remote!(root)
    %{root: root, remote: remote, fixture: fixture}
  end

  test "publishes the exact candidate without force and reconciles its remote ref", context do
    run_id = context.fixture.work_order["id"]

    assert {:ok, outcome} = Publication.publish(context.fixture.repository, run_id)
    assert outcome.candidate_commit == context.fixture.candidate
    assert outcome.effect["status"] == "confirmed"

    {remote_commit, 0} =
      System.cmd("git", ["--git-dir", context.remote, "rev-parse", "refs/heads/#{outcome.branch}"])

    assert String.trim(remote_commit) == context.fixture.candidate

    receipt =
      context.fixture.repository.runtime_dir
      |> Path.join(outcome.receipt["relative_path"])
      |> File.read!()
      |> Hancho.JSON.decode!()

    assert receipt["local_candidate_commit"] == receipt["remote_candidate_commit"]
    assert {:ok, again} = Publication.publish(context.fixture.repository, run_id)
    assert again.effect["id"] == outcome.effect["id"]
  end

  test "creates one pull request, observes gates, merges with authority, and closes records in order",
       context do
    repository = context.fixture.repository
    run_id = context.fixture.work_order["id"]
    assert {:ok, publication} = Publication.publish(repository, run_id)

    {gh, gh_state} = github_fixture!(context.fixture.candidate)
    bw = beadwork_fixture!()
    previous_gh = System.get_env("HANCHO_GH")
    previous_bw = System.get_env("HANCHO_BW")
    System.put_env("HANCHO_GH", gh)
    System.put_env("HANCHO_BW", bw)

    on_exit(fn ->
      restore_env("HANCHO_GH", previous_gh)
      restore_env("HANCHO_BW", previous_bw)
    end)

    assert :ok =
             WorkRecords.link(repository, run_id,
               github_issue: "https://github.com/acme/repo/issues/10",
               beadwork: "bw-10"
             )

    assert {:ok, first_pr} = PullRequest.open(repository, run_id)
    assert first_pr.pull_request["headRefOid"] == context.fixture.candidate
    assert {:ok, second_pr} = PullRequest.open(repository, run_id)
    assert second_pr.effect["id"] == first_pr.effect["id"]
    assert String.trim(File.read!(Path.join(gh_state, "create-count"))) == "1"

    assert {:ok, stale_authority} =
             Journal.request_decision(repository, run_id, "merge_authority", %{
               candidate_commit: "stale-candidate",
               pull_request: "https://github.com/acme/repo/pull/1"
             })

    assert {:ok, _} =
             Operations.decide(
               repository,
               stale_authority["id"],
               "approved",
               "owner",
               "This approval is for a stale candidate."
             )

    assert {:error, %{code: :merge_authority_required}} =
             Merge.merge(repository, run_id, "https://github.com/acme/repo/pull/1")

    assert {:ok, [decision]} = Journal.open_decisions(repository)
    assert decision["kind"] == "merge_authority"

    assert {:ok, _} =
             Operations.decide(
               repository,
               decision["id"],
               "approved",
               "owner",
               "Exact candidate and gates approved"
             )

    assert {:ok, merged} =
             Merge.merge(repository, run_id, "https://github.com/acme/repo/pull/1")

    assert get_in(merged.observation, ["mergeCommit", "oid"]) == "merged-fixture-oid"

    assert {:ok, closed} =
             Closure.close(repository, run_id, "The accepted result works.",
               learning: "Check remote freshness earlier.",
               expected_result: "Reduce target-change stops."
             )

    assert closed.beadwork["status"] == "confirmed"
    assert closed.github["status"] == "confirmed"
    assert closed.proposal["status"] == "proposed"
    assert {:ok, [proposal_decision]} = Journal.open_decisions(repository)
    assert proposal_decision["kind"] == "standard_work_change"

    command_log = File.read!(Path.join(gh_state, "commands.log"))
    assert command_log =~ "pr create"
    assert command_log =~ "pr merge"
    assert command_log =~ "issue close"
    assert publication.effect["status"] == "confirmed"
  end

  test "requires new validation when the remote target changes", context do
    repository = context.fixture.repository
    run_id = context.fixture.work_order["id"]
    assert {:ok, _} = Publication.publish(repository, run_id)

    other = temporary_git_repository!("changed-target")
    {_output, 0} = System.cmd("git", ["-C", other, "remote", "add", "origin", context.remote])
    File.write!(Path.join(other, "change.txt"), "changed\n")
    {_output, 0} = System.cmd("git", ["-C", other, "add", "."])
    {_output, 0} = System.cmd("git", ["-C", other, "commit", "-q", "-m", "Target changed"])

    {_output, 0} =
      System.cmd("git", ["-C", other, "push", "-q", "--force", "origin", "main:main"])

    assert {:error, %{code: :target_changed}} = Merge.merge(repository, run_id, "pr-1")
  end

  test "validates a delivery without a write and runs only after explicit opt-in", context do
    repository = context.fixture.repository
    run_id = context.fixture.work_order["id"]
    marker = Path.join(temporary_directory!("deploy"), "deployed")
    command = Path.join(Path.dirname(marker), "deploy")
    File.write!(command, "#!/bin/sh\nprintf deployed > '#{marker}'\n")
    File.chmod!(command, 0o700)

    request = %Request{
      run_id: run_id,
      adapter: "phoenix",
      artifact: context.fixture.candidate,
      target_environment: "staging",
      authority: "owner-approved",
      checks: ["health check"],
      recovery_method: "Run the rollback command.",
      secret_env: ["DEPLOY_TOKEN"],
      options: %{"command" => command, "arguments" => []}
    }

    assert {:ok, dry_run} = Delivery.run(repository, request)
    assert dry_run.result.status == "contained"
    refute File.exists?(marker)

    assert {:ok, delivered} = Delivery.run(repository, request, dry_run: false, opt_in: true)
    assert delivered.result.status == "confirmed"
    assert File.read!(marker) == "deployed"

    invalid = %{request | secret_env: ["literal-secret-value"]}
    assert {:error, %{code: :invalid_delivery_request}} = Delivery.run(repository, invalid)
  end

  defp github_fixture!(candidate) do
    root = temporary_directory!("github")
    script = Path.join(root, "gh")

    File.write!(
      script,
      """
      #!/bin/sh
      printf '%s\n' "$*" >> "#{root}/commands.log"
      if [ "$1 $2" = "pr list" ]; then
        if [ -f "#{root}/created" ]; then
          printf '[{"number":1,"url":"https://github.com/acme/repo/pull/1","headRefOid":"#{candidate}","baseRefName":"main","state":"OPEN"}]\n'
        else
          printf '[]\n'
        fi
      elif [ "$1 $2" = "pr create" ]; then
        touch "#{root}/created"
        count=0; [ -f "#{root}/create-count" ] && count=$(cat "#{root}/create-count")
        expr "$count" + 1 > "#{root}/create-count"
        echo 'https://github.com/acme/repo/pull/1'
      elif [ "$1 $2" = "pr checks" ]; then
        printf '[{"name":"test","state":"SUCCESS","bucket":"pass","link":"https://ci.example/1"}]\n'
      elif [ "$1 $2" = "pr merge" ]; then
        touch "#{root}/merged"
        echo merged
      elif [ "$1 $2" = "pr view" ]; then
        if [ -f "#{root}/merged" ]; then
          printf '{"state":"MERGED","headRefOid":"#{candidate}","baseRefName":"main","url":"https://github.com/acme/repo/pull/1","mergeCommit":{"oid":"merged-fixture-oid"}}\n'
        else
          printf '{"state":"OPEN","headRefOid":"#{candidate}","baseRefName":"main","reviewDecision":"APPROVED","reviews":[{"state":"APPROVED"}]}\n'
        fi
      elif [ "$1 $2" = "issue close" ]; then
        echo closed
      else
        echo '{}'
      fi
      """
    )

    File.chmod!(script, 0o700)
    {script, root}
  end

  defp beadwork_fixture! do
    root = temporary_directory!("beadwork-close")
    script = Path.join(root, "bw")
    File.write!(script, "#!/bin/sh\necho '{}'\n")
    File.chmod!(script, 0o700)
    script
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
