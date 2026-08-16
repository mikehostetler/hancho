defmodule Hancho.FactoryCLITest do
  use Hancho.RepositoryCase, async: false

  import ExUnit.CaptureIO

  alias Hancho.Factory.{Client, Controller, Store}
  alias Hancho.Repository

  test "submits detached work through the CLI and follows normalized logs until stop" do
    root = temporary_git_repository!("factory-cli")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    assert {:ok, controller} = Controller.start_link(repository)

    follower =
      Task.async(fn ->
        capture_io(fn ->
          assert Hancho.CLI.run(["logs", "--follow", "--repo", root]) == 0
        end)
      end)

    Process.sleep(100)

    submission =
      capture_io(fn ->
        assert Hancho.CLI.run([
                 "run",
                 "walking_skeleton",
                 "detached-cli",
                 "--detach",
                 "--repo",
                 root,
                 "--json"
               ]) == 0
      end)
      |> Hancho.JSON.decode!()

    assert submission["result"] == "accepted"
    queue_id = submission["item"]["id"]

    assert_eventually(fn ->
      match?({:ok, %{"status" => "complete"}}, Store.get(repository, queue_id))
    end)

    monitor = Process.monitor(controller)
    assert {:ok, _} = Client.request(repository, "down")
    output = Task.await(follower, 5_000)
    assert output =~ "factory"
    assert output =~ "harness_completed"
    assert output =~ "Log follow ended"

    assert_receive {:DOWN, ^monitor, :process, ^controller, :normal}, 3_000

    status =
      capture_io(fn -> assert Hancho.CLI.run(["status", "--repo", root, "--json"]) == 0 end)
      |> Hancho.JSON.decode!()

    assert status["state"] == "stopped"
    assert status["next_command"] == "hancho up"
  end

  defp assert_eventually(fun, attempts \\ 100)
  defp assert_eventually(_fun, 0), do: flunk("Condition did not become true.")

  defp assert_eventually(fun, attempts) do
    if fun.(),
      do: assert(true),
      else:
        (
          Process.sleep(50)
          assert_eventually(fun, attempts - 1)
        )
  end
end
