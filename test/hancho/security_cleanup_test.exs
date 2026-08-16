defmodule Hancho.SecurityCleanupTest do
  use Hancho.RepositoryCase, async: false

  alias Hancho.{Artifacts, Cleanup, Config, Journal, Redactor, Repository, Runner, SQLite, Store}

  setup do
    root = temporary_git_repository!("security")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    %{root: root, repository: repository}
  end

  test "redacts configured patterns, known tokens, and hostile binary output", context do
    config_path = Repository.config_path(context.repository)

    File.write!(
      config_path,
      File.read!(config_path) <> "\n[credentials]\napi_token = \"HANCHO_TEST_TOKEN\"\n"
    )

    previous = System.get_env("HANCHO_TEST_TOKEN")
    System.put_env("HANCHO_TEST_TOKEN", "super-secret-value")

    on_exit(fn ->
      if previous,
        do: System.put_env("HANCHO_TEST_TOKEN", previous),
        else: System.delete_env("HANCHO_TEST_TOKEN")
    end)

    assert {:ok, config} = Config.load(context.repository)
    redacted = Redactor.redact("token=abc super-secret-value Authorization: Bearer xyz", config)
    refute redacted =~ "abc"
    refute redacted =~ "super-secret-value"
    refute redacted =~ "xyz"
    assert redacted =~ "[REDACTED]"

    assert Redactor.redact(<<255, 254, 253>>, config) =~ "INVALID UTF-8"
  end

  test "uses current-user permissions and cleans only expired safe evidence", context do
    assert {:ok, outcome} = Runner.run(context.repository, "walking_skeleton", "cleanup-run")
    run_id = outcome.work_order["id"]
    assert {:ok, artifacts} = Artifacts.list(context.repository, run_id)

    runtime_mode = File.stat!(context.repository.runtime_dir).mode |> Bitwise.band(0o777)
    assert runtime_mode == 0o700

    Enum.each(artifacts, fn artifact ->
      path = Path.join(context.repository.runtime_dir, artifact["relative_path"])
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end)

    assert :ok =
             SQLite.execute(
               Store.path(context.repository),
               "UPDATE artifacts SET created_at = '2020-01-01T00:00:00Z' WHERE run_id = #{SQLite.quote(run_id)};"
             )

    assert {:ok, before_events} = Journal.events(context.repository, run_id)
    assert {:ok, dry_run} = Cleanup.run(context.repository)
    assert dry_run.mode == "dry_run"
    assert dry_run.artifact_candidates != []

    assert Enum.all?(dry_run.artifact_candidates, fn artifact ->
             File.exists?(Path.join(context.repository.runtime_dir, artifact["relative_path"]))
           end)

    assert {:ok, applied} = Cleanup.run(context.repository, apply: true, actor: "test-owner")
    assert applied.removed != []
    assert {:ok, audit_events} = Cleanup.events(context.repository)
    assert length(audit_events) == length(applied.removed)
    assert Enum.all?(audit_events, &(&1["actor"] == "test-owner"))
    assert {:ok, after_events} = Journal.events(context.repository, run_id)
    assert after_events == before_events
  end

  test "does not clean evidence for active or uncertain work", context do
    {:ok, config} = Config.load(context.repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    {:ok, active} = Journal.create_work_order(context.repository, config, definition, "active")

    {:ok, artifact} =
      Artifacts.write(context.repository, active["id"], "log", "active.log", "data",
        retention: "sensitive_raw"
      )

    :ok =
      SQLite.execute(
        Store.path(context.repository),
        "UPDATE artifacts SET created_at = '2020-01-01T00:00:00Z' WHERE id = #{SQLite.quote(artifact["id"])};"
      )

    assert {:ok, plan} = Cleanup.run(context.repository)
    refute Enum.any?(plan.artifact_candidates, &(&1["id"] == artifact["id"]))
    assert File.exists?(Path.join(context.repository.runtime_dir, artifact["relative_path"]))
  end
end
