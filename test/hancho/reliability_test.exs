defmodule Hancho.ReliabilityTest do
  use Hancho.RepositoryCase, async: false

  @moduletag :integration

  alias Hancho.Factory.{Client, Controller, Store}
  alias Hancho.{Repository, SQLite}

  test "processes several work orders without exceeding the configured WIP limit" do
    root = temporary_git_repository!("long-run")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    config_path = Repository.config_path(repository)

    config =
      config_path
      |> File.read!()
      |> String.replace("wip_limit = 1", "wip_limit = 2", global: false)
      |> String.replace("command = \"fake\"", "command = \"fake\"\ndelay_ms = 250", global: false)

    File.write!(config_path, config)
    {:ok, repository} = Repository.discover(root)
    assert {:ok, controller} = Controller.start_link(repository)

    ids =
      Enum.map(1..5, fn index ->
        assert {:ok, %{"item" => item}} =
                 Client.request(repository, "submit", %{
                   "workflow" => "walking_skeleton",
                   "work_ref" => "long-#{index}"
                 })

        item["id"]
      end)

    max_active = monitor_wip(repository, ids, 0, 200)
    assert max_active <= 2
    assert max_active == 2
    assert {:ok, items} = Store.list(repository)
    assert Enum.all?(items, &(&1["status"] == "complete"))

    assert {:ok, _} = Client.request(repository, "down")
    monitor = Process.monitor(controller)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 3_000
  end

  test "force stop marks active queue work failed and preserves restart evidence" do
    root = temporary_git_repository!("force-stop")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    config_path = Repository.config_path(repository)

    File.write!(
      config_path,
      String.replace(
        File.read!(config_path),
        "command = \"fake\"",
        "command = \"fake\"\ndelay_ms = 2000",
        global: false
      )
    )

    {:ok, repository} = Repository.discover(root)
    assert {:ok, controller} = Controller.start_link(repository)

    assert {:ok, %{"item" => item}} =
             Client.request(repository, "submit", %{
               "workflow" => "walking_skeleton",
               "work_ref" => "interrupt"
             })

    assert_eventually(fn ->
      match?({:ok, %{"status" => "active"}}, Store.get(repository, item["id"]))
    end)

    assert {:ok, %{"state" => "stopping"}} =
             Client.request(repository, "down", %{"force" => true})

    monitor = Process.monitor(controller)
    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 3_000
    assert {:ok, %{"status" => "failed"}} = Store.get(repository, item["id"])
  end

  test "surfaces a simulated full-disk SQLite failure without partial success" do
    root = temporary_directory!("disk-full")
    sqlite = Path.join(root, "sqlite3")
    File.write!(sqlite, "#!/bin/sh\necho 'database or disk is full' >&2\nexit 1\n")
    File.chmod!(sqlite, 0o700)
    previous = System.get_env("HANCHO_SQLITE3")
    System.put_env("HANCHO_SQLITE3", sqlite)

    on_exit(fn ->
      if previous,
        do: System.put_env("HANCHO_SQLITE3", previous),
        else: System.delete_env("HANCHO_SQLITE3")
    end)

    assert {:error, error} =
             SQLite.execute(
               Path.join(root, "state.sqlite3"),
               "BEGIN; CREATE TABLE facts(value); COMMIT;"
             )

    assert error.code == :sqlite_error
    assert error.message =~ "disk is full"
    refute File.exists?(Path.join(root, "state.sqlite3"))
  end

  test "waits for a database write lock and continues after the lock is released" do
    root = temporary_directory!("database-lock")
    database = Path.join(root, "state.sqlite3")
    assert :ok = SQLite.execute(database, "CREATE TABLE lock_test (value TEXT);")

    sqlite = System.find_executable("sqlite3")

    port =
      Port.open({:spawn_executable, sqlite}, [
        :binary,
        :exit_status,
        args: [database]
      ])

    Port.command(port, "BEGIN EXCLUSIVE;\nSELECT 'hancho-lock-held';\n")
    assert_receive {^port, {:data, output}}, 1_000
    assert output =~ "hancho-lock-held"

    blocked =
      Task.async(fn -> SQLite.execute(database, "INSERT INTO lock_test VALUES ('ok');") end)

    refute Task.yield(blocked, 50)

    Port.command(port, "COMMIT;\n.quit\n")
    assert :ok = Task.await(blocked, 2_000)
    assert_receive {^port, {:exit_status, 0}}, 1_000
    assert {:ok, [%{"value" => "ok"}]} = SQLite.query(database, "SELECT value FROM lock_test;")
  end

  defp monitor_wip(_repository, _ids, max_active, 0),
    do: flunk("Long-run queue did not finish; max active #{max_active}.")

  defp monitor_wip(repository, ids, max_active, attempts) do
    {:ok, status} = Client.request(repository, "status")
    active = get_in(status, ["wip", "active"])
    max_active = max(max_active, active)
    {:ok, items} = Store.list(repository)

    if Enum.all?(ids, fn id -> Enum.find(items, &(&1["id"] == id))["status"] == "complete" end) do
      max_active
    else
      Process.sleep(25)
      monitor_wip(repository, ids, max_active, attempts - 1)
    end
  end

  defp assert_eventually(fun, attempts \\ 80)
  defp assert_eventually(_fun, 0), do: flunk("Condition did not become true.")

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: assert(true),
      else:
        (
          Process.sleep(25)
          assert_eventually(fun, attempts - 1)
        )
  end
end
