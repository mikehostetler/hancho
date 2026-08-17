defmodule Hancho.WorkflowTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{Definition, Loader, Params, Runner, Store}

  defmodule Beadwork do
    def show(issue_id, _options), do: {:ok, issue(issue_id, "open")}
    def start(issue_id, _options), do: {:ok, issue(issue_id, "in_progress")}
    def comment(issue_id, _text, _options), do: {:ok, %{"id" => issue_id}}
    def close(issue_id, _options), do: {:ok, issue(issue_id, "closed")}
    def sync(_options), do: {:ok, "synced"}

    defp issue(issue_id, status) do
      %{
        "id" => issue_id,
        "title" => "Add an implementation file",
        "description" => "Create implemented.txt",
        "type" => "task",
        "status" => status,
        "blocked_by" => []
      }
    end
  end

  defmodule Harness do
    def run(:codex, _prompt, options) do
      File.write!(Path.join(options[:cwd], "implemented.txt"), "implemented\n")

      {:ok,
       Jido.Harness.RunResult.new!(%{
         run_id: "agent-run",
         provider: :codex,
         status: :completed,
         text: "done"
       })}
    end
  end

  defmodule Command do
    def run(_executable, ["test"], _options) do
      {:ok, %Hancho.Command.Result{stdout: "tests passed\n", stderr: "", exit_status: 0}}
    end
  end

  defmodule Registry do
    def fetch("Test.First"), do: {:ok, :first}
    def fetch("Test.Second"), do: {:ok, :second}
    def fetch(name), do: {:error, "Unknown test action: #{name}"}
  end

  defmodule Executor do
    def run(:first, %{"value" => value}, _context), do: {:ok, %{value: value + 1}}
    def run(:second, %{"value" => value}, _context), do: {:ok, %{value: value * 2}}
  end

  defmodule MissingOutputExecutor do
    def run(:first, %{"value" => value}, _context), do: {:ok, %{other: value}}
  end

  test "loads the default ordered workflow and validates action references" do
    directory = temporary_directory()
    path = Path.join(directory, "implement.yaml")
    File.write!(path, Hancho.Workflow.Default.implementation())

    assert Hancho.Workflow.Default.implementation() ==
             File.read!(Path.expand("../../priv/workflows/implement.yaml", __DIR__))

    assert Hancho.Workflow.Default.implementation_prompt() ==
             File.read!(Path.expand("../../priv/prompts/implement.md", __DIR__))

    assert {:ok, definition} = Loader.load_path(path)
    assert definition.name == "implement"
    assert length(definition.steps) == 10
    assert hd(definition.steps).name == "preflight"
    assert List.last(definition.steps).name == "close_issue"

    assert Enum.all?(definition.steps, fn step ->
             match?({:ok, _module}, Hancho.Workflow.Registry.fetch(step.action))
           end)
  end

  test "rejects duplicate names and forward step references" do
    duplicate = %{
      "name" => "bad",
      "version" => 1,
      "steps" => [
        %{"name" => "same", "action" => "Test.First", "params" => %{}},
        %{"name" => "same", "action" => "Test.Second", "params" => %{}}
      ]
    }

    assert {:error, "Step names must be unique."} = Definition.new(duplicate)

    forward = %{
      "name" => "bad",
      "version" => 1,
      "steps" => [
        %{
          "name" => "first",
          "action" => "Test.First",
          "params" => %{"value" => "$steps.second.value"}
        },
        %{"name" => "second", "action" => "Test.Second", "params" => %{}}
      ]
    }

    assert {:error, message} = Definition.new(forward)
    assert message =~ "refers to unavailable step 'second'"
  end

  test "resolves input, run, and prior-step values through nested data" do
    scope = %{
      "input" => %{"issue_id" => "hancho-123"},
      "run" => %{"id" => "run-1"},
      "steps" => %{"first" => %{"value" => 4}}
    }

    params = %{
      "issue" => "$input.issue_id",
      "path" => ["$run.id", %{"number" => "$steps.first.value"}],
      "literal" => "plain"
    }

    assert Params.resolve(params, scope) ==
             {:ok,
              %{
                "issue" => "hancho-123",
                "path" => ["run-1", %{"number" => 4}],
                "literal" => "plain"
              }}

    assert Params.resolve("$steps.missing.value", scope) ==
             {:error, "Parameter reference was not found: $steps.missing.value"}
  end

  test "runs steps in order and keeps completed state in Bedrock" do
    {project, workflow_path} = project_with_workflow(successful_workflow())
    assert File.exists?(workflow_path)

    assert {:ok, result} =
             Runner.run(project, "test", %{"number" => 3},
               run_id: "run-success",
               registry: Registry,
               executor: Executor,
               log: :disabled,
               flush_state: false
             )

    assert result.status == :completed

    assert result.outputs == %{
             "first" => %{"value" => 4},
             "second" => %{"value" => 8}
           }

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "run-success")
    assert run["status"] == "completed"
    assert run["workflow_yaml"] == successful_workflow()
    assert run["workflow_sha256"] == sha256(successful_workflow())
    assert Jason.decode!(run["outputs_json"]) == result.outputs

    assert {:ok, steps} = Store.list_steps(store, "run-success")
    assert Enum.map(steps, & &1["status"]) == ["completed", "completed"]
    Store.close(store)
  end

  test "stops on a missing parameter and keeps the Andon state in Bedrock" do
    {project, _workflow_path} = project_with_workflow(successful_workflow())

    assert {:ok, result} =
             Runner.run(project, "test", %{"number" => 3},
               run_id: "run-stopped",
               registry: Registry,
               executor: MissingOutputExecutor,
               log: :disabled,
               flush_state: false
             )

    assert result.status == :stopped
    assert result.current_step == "second"
    assert result.error =~ "$steps.first.value"

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "run-stopped")
    assert run["status"] == "stopped"
    assert run["current_step"] == "second"

    assert {:ok, steps} = Store.list_steps(store, "run-stopped")
    assert Enum.map(steps, & &1["status"]) == ["completed", "stopped"]
    Store.close(store)
  end

  test "runs the default workflow through all approved actions" do
    repository = temporary_repository()
    project = Hancho.Project.new(repository)
    File.mkdir_p!(project.worktrees_path)
    assert :ok = Hancho.Workflow.Default.install(project)
    write_quiet_log_config(project)

    assert {:ok, result} =
             Runner.run(
               project,
               "implement",
               %{"repo_path" => repository, "issue_id" => "hancho-123"},
               run_id: "full-run",
               flush_state: false,
               services: %{beadwork: Beadwork, harness: Harness, command: Command}
             )

    assert result.status == :completed
    assert map_size(result.outputs) == 10
    assert result.outputs["render_prompt"]["rendered"] =~ "Implement Beadwork task hancho-123"
    assert result.outputs["close_issue"]["status"] == "closed"
    assert File.read!(Path.join(repository, "implemented.txt")) == "implemented\n"
    refute File.exists?(Path.join(project.worktrees_path, "full-run"))

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert {:ok, run} = Store.fetch_run(store, "full-run")
    assert run["workflow_yaml"] == Hancho.Workflow.Default.implementation()
    assert run["workflow_sha256"] == sha256(Hancho.Workflow.Default.implementation())

    assert {:ok, steps} = Store.list_steps(store, "full-run")
    assert Enum.all?(steps, &(&1["status"] == "completed"))
    Store.close(store)

    events = read_events(Path.join(project.logs_path, "factory.jsonl"))
    workflow_event = Enum.find(events, &(&1["event"] == "workflow.snapshot"))
    prompt_event = Enum.find(events, &(&1["event"] == "prompt.snapshot"))

    assert workflow_event["metadata"]["yaml"] == Hancho.Workflow.Default.implementation()
    assert workflow_event["metadata"]["sha256"] == run["workflow_sha256"]
    assert prompt_event["metadata"]["template"] == Hancho.Workflow.Default.implementation_prompt()
    assert prompt_event["metadata"]["rendered"] == result.outputs["render_prompt"]["rendered"]
    assert prompt_event["metadata"]["sha256"] == result.outputs["render_prompt"]["sha256"]
  end

  defp successful_workflow do
    """
    name: test
    version: 1
    steps:
      - name: first
        action: Test.First
        params:
          value: "$input.number"
      - name: second
        action: Test.Second
        params:
          value: "$steps.first.value"
    """
  end

  defp project_with_workflow(contents) do
    root = temporary_directory()
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.workflows_path)
    path = Path.join(project.workflows_path, "test.yaml")
    File.write!(path, contents)
    {project, path}
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-workflow-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    path
  end

  defp temporary_repository do
    path = temporary_directory()
    {_output, 0} = System.cmd("git", ["init", "--initial-branch=main", path])
    File.write!(Path.join(path, ".gitignore"), "/.hancho/\n")

    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.name", "Hancho Test"])
    {_output, 0} = System.cmd("git", ["-C", path, "config", "user.email", "hancho@example.test"])
    {_output, 0} = System.cmd("git", ["-C", path, "add", ".gitignore"])

    {_output, 0} =
      System.cmd("git", ["-C", path, "commit", "-m", "chore: initialize test repository"])

    path
  end

  defp write_quiet_log_config(project) do
    {:ok, config} = Hancho.Config.default(project)
    config = %{config | logs: %{config.logs | console: false, sync_interval_ms: 0}}
    {:ok, contents} = Hancho.Config.encode(config)
    File.write!(project.config_path, contents)
  end

  defp read_events(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end

  defp sha256(contents), do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
