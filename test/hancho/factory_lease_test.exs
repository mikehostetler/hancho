defmodule Hancho.FactoryLeaseTest do
  use ExUnit.Case, async: true

  alias Hancho.FactoryLease

  test "allows one mutating factory owner" do
    project = project()
    assert {:ok, lease} = FactoryLease.acquire(project, lease_command: "first")

    assert {:error, {:factory_busy, owner}} =
             FactoryLease.acquire(project, lease_command: "second")

    assert owner["command"] == "first"
    assert :ok = FactoryLease.release(lease)
    refute File.exists?(lease.path)
  end

  test "reclaims a stale owner record" do
    project = project()
    path = Path.join(project.hancho_dir, "factory.lock")
    owner_path = Path.join(path, "owner.json")
    File.mkdir_p!(path)

    File.write!(
      owner_path,
      Jason.encode!(%{
        "schema_version" => 1,
        "token" => "stale-owner",
        "command" => "old run",
        "os_pid" => "0",
        "host" => "test",
        "started_at_ms" => 0,
        "heartbeat_at_ms" => 0
      })
    )

    assert {:ok, lease} =
             FactoryLease.acquire(project, lease_command: "recovery", lease_stale_after_ms: 1)

    assert lease.token != "stale-owner"
    assert :ok = FactoryLease.release(lease)
  end

  test "keeps an active lease fresh for a short stale interval" do
    project = project()
    assert {:ok, lease} = FactoryLease.acquire(project, lease_stale_after_ms: 300)

    Process.sleep(700)

    assert {:error, {:factory_busy, _owner}} =
             FactoryLease.acquire(project, lease_stale_after_ms: 300)

    assert :ok = FactoryLease.release(lease)
  end

  test "stops the heartbeat when its owner exits normally" do
    project = project()
    parent = self()

    owner =
      spawn(fn ->
        {:ok, lease} = FactoryLease.acquire(project, lease_stale_after_ms: 50)
        send(parent, {:lease, lease})
      end)

    monitor = Process.monitor(owner)
    assert_receive {:lease, lease}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 1_000
    refute eventually_alive?(lease.heartbeat_pid)

    Process.sleep(60)
    assert {:ok, recovered} = FactoryLease.acquire(project, lease_stale_after_ms: 50)
    assert :ok = FactoryLease.release(recovered)
  end

  test "allows exactly one concurrent lease owner" do
    project = project()
    parent = self()

    workers =
      for _index <- 1..8 do
        Task.async(fn ->
          receive do
            :acquire -> :ok
          end

          result = FactoryLease.acquire(project)
          send(parent, {:lease_result, self(), result})

          case result do
            {:ok, lease} ->
              receive do
                :release -> FactoryLease.release(lease)
              end

            {:error, _reason} ->
              :ok
          end
        end)
      end

    Enum.each(workers, &send(&1.pid, :acquire))

    results =
      for _index <- workers do
        receive do
          {:lease_result, worker, result} -> {worker, result}
        end
      end

    assert [{owner, {:ok, _lease}}] =
             Enum.filter(results, fn {_worker, result} -> match?({:ok, _lease}, result) end)

    assert Enum.count(results, fn {_worker, result} ->
             match?({:error, {:factory_busy, _owner}}, result)
           end) == 7

    send(owner, :release)
    Enum.each(workers, &Task.await(&1, 1_000))
  end

  test "releases the lease when factory work raises" do
    project = project()

    assert {:error, {:exception, %RuntimeError{message: "factory failed"}}} =
             FactoryLease.with_lease(project, [], fn -> raise "factory failed" end)

    refute File.exists?(Path.join(project.hancho_dir, "factory.lock"))
  end

  defp project do
    path = Path.join(System.tmp_dir!(), "hancho-lease-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn -> File.rm_rf!(path) end)
    Hancho.Project.new(path)
  end

  defp eventually_alive?(pid, attempts \\ 20)
  defp eventually_alive?(pid, 0), do: Process.alive?(pid)

  defp eventually_alive?(pid, attempts) do
    if Process.alive?(pid) do
      Process.sleep(10)
      eventually_alive?(pid, attempts - 1)
    else
      false
    end
  end
end
