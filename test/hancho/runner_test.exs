defmodule Hancho.RunnerTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Journal, ReadModel, Repository, Runner}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    %{root: root, repository: repository}
  end

  test "runs the walking skeleton through a fake harness and keeps durable evidence", context do
    assert {:ok, outcome} = Runner.run(context.repository, "walking_skeleton", "work-100")
    assert outcome.work_order["state"] == "complete"
    assert outcome.work_order["status"] == "complete"

    assert {:ok, data} = ReadModel.show(context.repository, outcome.work_order["id"])

    assert Enum.map(data.events, & &1["event"]) == [
             "created",
             "start",
             "guidance_resolved",
             "harness_started",
             "harness_completed",
             "harness_succeeded"
           ]

    assert [%{"status" => "completed"}] = data.actions
    assert [%{"status" => "success", "adapter" => "builtin:fake"}] = data.harness_sessions
    assert Enum.any?(data.artifacts, &(&1["kind"] == "prompt"))
    assert Enum.count(data.artifacts, &(&1["kind"] == "log")) == 2

    # A new repository value simulates a new escript process.
    assert {:ok, reopened} = Repository.discover(context.root)
    assert {:ok, persisted} = Journal.get_work_order(reopened, outcome.work_order["id"])
    assert persisted["state"] == "complete"
  end

  test "records a visible stopped result when the fake harness fails", context do
    config_path = Path.join(context.root, ".hancho/config.toml")
    config = File.read!(config_path)

    config =
      String.replace(config, "command = \"fake\"", "command = \"fake\"\nmode = \"failure\"",
        global: false
      )

    File.write!(config_path, config)

    assert {:ok, outcome} = Runner.run(context.repository, "walking_skeleton", "work-101")
    assert outcome.work_order["state"] == "stopped"
    assert outcome.work_order["status"] == "stopped"
  end

  test "does not execute Build.V1 through the generic runner", context do
    assert {:error, %{code: :workflow_not_executable}} =
             Runner.run(context.repository, "build", "work-102")
  end
end
