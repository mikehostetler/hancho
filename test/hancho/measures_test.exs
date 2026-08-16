defmodule Hancho.MeasuresTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Journal, Measures, Repository, Runner, SQLite, Store}

  test "reports defined flow facts without person or code-volume rankings" do
    root = temporary_git_repository!("measures")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    assert {:ok, outcome} = Runner.run(repository, "walking_skeleton", "measure-run")
    run_id = outcome.work_order["id"]

    assert {:ok, _} =
             Journal.record_event(repository, run_id, "review_rework", reason: "Test rework")

    assert {:ok, _} =
             Journal.record_event(repository, run_id, "andon", reason: "Dependency unavailable")

    assert :ok =
             SQLite.execute(
               Store.path(repository),
               "INSERT INTO delivery_requests (id, run_id, adapter, artifact, target_environment, authority, checks_json, recovery_method, secret_env_json, request_json, status, requested_at) VALUES ('delivery-failed', #{SQLite.quote(run_id)}, 'phoenix', 'commit', 'test', 'owner', '[]', 'rollback', '[]', '{}', 'uncertain', '2026-01-01T00:00:00Z');"
             )

    assert {:ok, report} = Measures.report(repository)
    assert report.values.rework_count == 1
    assert report.values.failed_delivery_count == 1
    assert report.values.andon_causes["Dependency unavailable"] == 1
    assert report.definitions.active_wip.source == "work_orders.status"
    assert report.policy =~ "Do not rank people"
    refute Hancho.JSON.encode!(report) =~ "lines of code"
  end
end
