defmodule Hancho.OperationsTest do
  use Hancho.RepositoryCase, async: true

  @moduletag :integration

  alias Hancho.Workflow.Event
  alias Hancho.{Config, Journal, Operations, Repository, Runner}

  test "cancels active work idempotently and preserves its events" do
    {repository, config, definition} = initialized_context()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "cancel-work")
    {:ok, _} = Journal.transition(repository, work_order["id"], definition, %Event{name: "start"})

    assert {:ok, cancelled} =
             Operations.cancel(repository, work_order["id"], "owner", "No longer needed")

    assert cancelled["state"] == "cancelled"
    assert {:ok, same} = Operations.cancel(repository, work_order["id"], "owner", "Repeat")
    assert same["state"] == "cancelled"
    assert {:ok, events} = Journal.events(repository, work_order["id"])
    assert Enum.at(events, -1)["reason"] == "No longer needed"
  end

  test "resumes a stopped walking skeleton with a fresh adapter attempt" do
    {repository, _config, _definition} = initialized_context(mode: "failure")
    assert {:ok, stopped} = Runner.run(repository, "walking_skeleton", "resume-work")
    assert stopped.work_order["state"] == "stopped"

    config_path = Path.join(repository.runtime_dir, "config.toml")

    File.write!(
      config_path,
      String.replace(File.read!(config_path), "mode = \"failure\"", "mode = \"success\"")
    )

    assert {:ok, resumed} = Operations.resume(repository, stopped.work_order["id"])
    assert resumed.work_order["state"] == "complete"
    assert {:ok, events} = Journal.events(repository, stopped.work_order["id"])
    assert Enum.any?(events, &(&1["event"] == "resume_requested"))
  end

  test "records a decision answer as a same-state journal event" do
    {repository, config, definition} = initialized_context()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "decision-work")

    {:ok, decision} =
      Journal.request_decision(repository, work_order["id"], "risk", %{question: "Proceed?"})

    assert {:ok, answered} =
             Operations.decide(
               repository,
               decision["id"],
               "approved",
               "owner",
               "Risk reviewed"
             )

    assert answered["status"] == "approved"
    assert {:ok, events} = Journal.events(repository, work_order["id"])
    assert Enum.at(events, -1)["event"] == "decision_approved"
    assert :ok = Journal.verify_replay(repository, work_order["id"], definition)
  end

  defp initialized_context(options \\ []) do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)

    if mode = Keyword.get(options, :mode) do
      path = Path.join(root, ".hancho/config.toml")

      File.write!(
        path,
        String.replace(
          File.read!(path),
          "command = \"fake\"",
          "command = \"fake\"\nmode = \"#{mode}\"",
          global: false
        )
      )
    end

    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    {repository, config, Hancho.Workflows.WalkingSkeleton.V1.definition()}
  end
end
