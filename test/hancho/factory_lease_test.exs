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
end
