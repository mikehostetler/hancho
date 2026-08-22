defmodule Hancho.SchemaTest do
  use ExUnit.Case, async: true

  alias Hancho.Command.Result
  alias Hancho.Config
  alias Hancho.Config.Error
  alias Hancho.Config.Logs
  alias Hancho.Config.Repo
  alias Hancho.Log.Event
  alias Hancho.Demand.Finding
  alias Hancho.Demand.Record
  alias Hancho.GitHub.Issue, as: GitHubIssue
  alias Hancho.Project
  alias Hancho.Workflow.Definition
  alias Hancho.Workflow.ArtifactSpec
  alias Hancho.Workflow.AttentionRecord
  alias Hancho.Workflow.HandoffRecord
  alias Hancho.Workflow.OnError
  alias Hancho.Workflow.QueueResult
  alias Hancho.Workflow.RepairRecord
  alias Hancho.Workflow.Result, as: WorkflowResult
  alias Hancho.Workflow.Step
  alias Hancho.Workflow.Role

  @schema_modules [
    Result,
    Config,
    Error,
    Logs,
    Repo,
    Event,
    Finding,
    Record,
    GitHubIssue,
    Project,
    Definition,
    ArtifactSpec,
    AttentionRecord,
    HandoffRecord,
    OnError,
    QueueResult,
    RepairRecord,
    Step,
    Role,
    WorkflowResult
  ]

  test "defines every Hancho data struct with a Zoi struct schema" do
    for module <- @schema_modules do
      assert %Zoi.Types.Struct{module: ^module} = module.schema()
    end
  end

  test "constructs and validates command results" do
    assert {:ok, %Result{stdout: "ok", stderr: "", exit_status: 0}} =
             Result.new(stdout: "ok", stderr: "", exit_status: 0)

    assert {:error, errors} = Result.new(stdout: "ok", stderr: "", exit_status: -1)
    assert Enum.any?(errors, &(&1.path == [:exit_status]))
  end

  test "constructs nested configuration structs with defaults" do
    assert {:ok, %Config{} = config} =
             Config.new(%{
               version: 1,
               repo: %{path: "/work/repo"},
               logs: %{}
             })

    assert config.repo == %Repo{path: "/work/repo"}
    assert config.logs.format == :jsonl
    assert config.logs.path == "factory.jsonl"

    assert {:error, errors} = Config.new(%{version: 2, repo: %{path: "/repo"}, logs: %{}})
    assert Enum.any?(errors, &(&1.path == [:version]))
  end

  test "validates repository and log configuration structs" do
    assert {:ok, %Repo{path: "/repo"}} = Repo.new(path: "/repo")
    assert {:error, repo_errors} = Repo.new(path: "")
    assert Enum.any?(repo_errors, &(&1.path == [:path]))

    assert {:ok, %Logs{} = logs} = Logs.new(%{})
    assert logs.enabled
    assert logs.max_files == 5

    assert {:error, log_errors} = Logs.new(path: "../outside.log")
    assert Enum.any?(log_errors, &(&1.path == [:path]))
  end

  test "constructs and validates configuration errors" do
    assert {:ok, %Error{} = error} =
             Error.new(kind: :read, path: "/repo/.hancho/config.toml", message: "cannot read")

    assert Exception.message(error) == "cannot read"
    assert error.details == []

    assert {:error, errors} =
             Error.new(kind: :unknown, path: "/repo/config.toml", message: "bad")

    assert Enum.any?(errors, &(&1.path == [:kind]))
  end

  test "validates complete project and activity event structs" do
    project = Project.new("/repo")
    assert {:ok, ^project} = Zoi.parse(Project.schema(), project)

    assert {:ok, event} = Event.new("ready")
    assert {:ok, ^event} = Zoi.parse(Event.schema(), event)
  end
end
