defmodule Hancho.Factory.ControllerTest do
  use Hancho.RepositoryCase, async: false

  alias Hancho.Factory.{Client, Controller, Store}
  alias Hancho.{Repository, SQLite}

  setup do
    root = temporary_git_repository!("controller")
    {:ok, repository} = Repository.discover(root)
    {:ok, _result} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)

    on_exit(fn ->
      if Client.running?(repository), do: Client.request(repository, "down", %{"force" => true})
    end)

    %{root: root, repository: repository}
  end

  test "owns one lock and accepts authenticated control commands", context do
    assert {:ok, controller} = Controller.start_link(context.repository)

    assert {:ok, %{"health" => "healthy", "state" => "operating"}} =
             Client.request(context.repository, "status")

    assert {:error, %{code: :factory_already_active}} = Controller.start_link(context.repository)

    metadata =
      context.repository
      |> Client.metadata_path()
      |> File.read!()
      |> Hancho.JSON.decode!()

    assert metadata["factory_id"]
    assert metadata["config_hash"]
    assert metadata["host"] == "foreground"
    assert metadata["health"] == "healthy"

    assert {:ok, _status} = Client.request(context.repository, "down")
    monitor = Process.monitor(controller)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 2_000
  end

  test "pause and continue are idempotent and preserve queue work", context do
    assert {:ok, controller} = Controller.start_link(context.repository)
    assert {:ok, %{"state" => "paused"}} = Client.request(context.repository, "pause")
    assert {:ok, %{"state" => "paused"}} = Client.request(context.repository, "pause")

    assert {:ok, %{"accepted" => true, "item" => item}} =
             Client.request(context.repository, "submit", %{
               "workflow" => "walking_skeleton",
               "work_ref" => "queued-while-paused"
             })

    Process.sleep(100)
    assert {:ok, %{"status" => "ready"}} = Store.get(context.repository, item["id"])

    assert {:ok, %{"state" => "operating"}} = Client.request(context.repository, "continue")
    assert {:ok, %{"state" => "operating"}} = Client.request(context.repository, "continue")

    assert_eventually(fn ->
      match?({:ok, %{"status" => "complete"}}, Store.get(context.repository, item["id"]))
    end)

    assert {:ok, events} = Store.events(context.repository)
    assert Enum.count(events, &(&1["event"] == "paused")) == 1
    assert Enum.count(events, &(&1["event"] == "continued")) == 1
    assert Enum.count(events, &(&1["event"] == "work_released")) == 1

    assert {:ok, _status} = Client.request(context.repository, "down")
    monitor = Process.monitor(controller)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 2_000
  end

  test "a restart exposes interrupted action and effect windows and does not release", context do
    assert :ok =
             SQLite.execute(
               Hancho.Store.path(context.repository),
               """
               INSERT INTO work_orders (id, repository_id, workflow_name, workflow_version, work_ref, state, status, config_hash, created_at, updated_at)
               VALUES ('run-interrupted', #{SQLite.quote(context.repository.id)}, 'walking_skeleton', 1, 'x', 'operating', 'active', 'hash', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
               INSERT INTO actions (id, run_id, station, kind, status, idempotency_key, requested_at, started_at)
               VALUES ('action-interrupted', 'run-interrupted', 'operate', 'run_harness', 'started', 'action-key', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');
               INSERT INTO effects (id, run_id, kind, target, status, idempotency_key, intent_at)
               VALUES ('effect-interrupted', 'run-interrupted', 'git_push', 'origin/test', 'intent', 'effect-key', '2026-01-01T00:00:00Z');
               """
             )

    assert {:ok, controller} = Controller.start_link(context.repository)
    assert {:ok, status} = Client.request(context.repository, "status")
    assert status["state"] == "unhealthy"
    assert [%{"status" => "uncertain"}] = status["uncertain_actions"]
    assert [%{"status" => "uncertain"}] = status["uncertain_effects"]

    assert {:error, %{code: "factory_not_accepting_work"}} =
             Client.request(context.repository, "submit", %{
               "workflow" => "walking_skeleton",
               "work_ref" => "must-not-release"
             })

    assert {:ok, _status} = Client.request(context.repository, "down", %{"force" => true})
    monitor = Process.monitor(controller)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 2_000

    assert {:ok, %{unresolved: 0}} =
             Hancho.Reconciler.reconcile_run(context.repository, "run-interrupted",
               checker: fn _repository, _effect ->
                 {:ok, "confirmed", %{observed: "fixture external state"}}
               end
             )

    assert {:ok, restarted} = Controller.start_link(context.repository)
    assert {:ok, %{"health" => "healthy"}} = Client.request(context.repository, "status")
    assert {:ok, _} = Client.request(context.repository, "down")
    restarted_monitor = Process.monitor(restarted)
    assert_receive {:DOWN, ^restarted_monitor, :process, ^restarted, :normal}, 2_000
  end

  test "replaces stale process metadata and rejects a changed factory identity", context do
    lock = Path.join(context.repository.runtime_dir, "locks/factory.lock")

    File.write!(
      lock,
      Hancho.JSON.encode!(%{pid: 999_999_999, started_at: "2020-01-01T00:00:00Z"})
    )

    File.chmod!(lock, 0o600)

    assert {:ok, controller} = Controller.start_link(context.repository)
    metadata_path = Client.metadata_path(context.repository)
    original = File.read!(metadata_path)
    changed = original |> Hancho.JSON.decode!() |> Map.put("factory_id", "wrong-factory")
    File.write!(metadata_path, Hancho.JSON.encode!(changed))

    assert {:error, %{code: "factory_identity_mismatch"}} =
             Client.request(context.repository, "status")

    File.write!(metadata_path, original)
    assert {:ok, _} = Client.request(context.repository, "down")
    monitor = Process.monitor(controller)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 3_000
  end

  test "one failed work item does not stop an unrelated queued work item", context do
    assert {:ok, controller} = Controller.start_link(context.repository)

    assert {:ok, %{"item" => failed}} =
             Client.request(context.repository, "submit", %{
               "workflow" => "missing_workflow",
               "work_ref" => "expected-failure"
             })

    assert {:ok, %{"item" => healthy}} =
             Client.request(context.repository, "submit", %{
               "workflow" => "walking_skeleton",
               "work_ref" => "isolated-success"
             })

    assert_eventually(fn ->
      match?({:ok, %{"status" => "failed"}}, Store.get(context.repository, failed["id"])) and
        match?({:ok, %{"status" => "complete"}}, Store.get(context.repository, healthy["id"]))
    end)

    assert {:ok, %{"health" => "healthy"}} = Client.request(context.repository, "status")
    monitor = Process.monitor(controller)
    assert {:ok, _} = Client.request(context.repository, "down")
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 3_000
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(50)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("Condition did not become true.")
end
