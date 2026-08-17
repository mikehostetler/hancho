defmodule Hancho.QueueTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{QueueReconciler, QueueRunner, Result, Store}

  defmodule Beadwork do
    def ready(_options) do
      {:ok,
       [
         issue("task-1"),
         %{"id" => "epic-1", "type" => "epic", "status" => "open", "blocked_by" => []},
         issue("task-2"),
         issue("task-3")
       ]}
    end

    defp issue(id) do
      %{"id" => id, "type" => "task", "status" => "open", "blocked_by" => []}
    end
  end

  defmodule ContainerReadyBeadwork do
    def ready(_options) do
      {:ok, [%{"id" => "epic-1", "type" => "epic", "status" => "open", "blocked_by" => []}]}
    end

    def list_all(_options) do
      {:ok,
       [
         issue("task-later", "open", ["task-next"], 20),
         issue("task-closed", "closed", [], 5),
         issue("task-next", "open", ["task-closed"], 10)
       ]}
    end

    defp issue(id, status, blocked_by, ordinal) do
      %{
        "id" => id,
        "type" => "task",
        "status" => status,
        "blocked_by" => blocked_by,
        "description" => "Queue ordinal: `#{ordinal}`"
      }
    end
  end

  defmodule Reconciler do
    def initial(project, _options) do
      {:ok, %{repository: project.root, branch: "main", head: "head-0", worktrees: []}}
    end

    def before_item(_project, queue, _options) do
      send(self(), {:reconciled, :before, queue["current_position"]})
      {:ok, summary(queue["expected_head"])}
    end

    def after_run(_project, queue, outputs, _options) do
      send(self(), {:reconciled, :after, queue["current_position"]})
      {:ok, summary(get_in(outputs, ["land", "commit"]) || queue["expected_head"])}
    end

    defp summary(head), do: %{branch: "main", head: head, clean: true, worktrees: []}
  end

  defmodule MismatchReconciler do
    def initial(project, _options) do
      {:ok, %{repository: project.root, branch: "main", head: "head-0", worktrees: []}}
    end

    def before_item(_project, _queue, _options) do
      {:error,
       %{
         code: "filesystem_out_of_sync",
         field: "head",
         expected: "head-0",
         actual: "head-other"
       }}
    end
  end

  defmodule WorkflowRunner do
    def run(_project, "implement", %{"issue_id" => issue_id}, options) do
      send(self(), {:ran, issue_id, options[:run_id]})

      Result.new(%{
        run_id: options[:run_id],
        workflow: "implement",
        status: :completed,
        current_step: nil,
        outputs: %{"land" => %{"commit" => "head-#{issue_id}"}},
        error: nil
      })
    end
  end

  defmodule StoppingWorkflowRunner do
    def run(_project, "implement", %{"issue_id" => "task-2"}, options) do
      send(self(), {:ran, "task-2", options[:run_id]})

      Result.new(%{
        run_id: options[:run_id],
        workflow: "implement",
        status: :stopped,
        current_step: "implement",
        outputs: %{},
        error: "agent stopped"
      })
    end

    def run(project, workflow, input, options),
      do: WorkflowRunner.run(project, workflow, input, options)
  end

  defmodule MemoryStore do
    def open(_path), do: {:ok, :memory}
    def close(_store), do: :ok

    def create_queue(_store, id, workflow, source, items, state) do
      queue = %{
        "id" => id,
        "workflow_name" => workflow,
        "source" => source,
        "status" => "running",
        "repository" => state.repository,
        "expected_branch" => state.branch,
        "expected_head" => state.head,
        "current_position" => 0,
        "current_run_id" => nil,
        "items" =>
          Enum.map(items, fn item ->
            %{
              "position" => item.position,
              "issue_id" => item.issue_id,
              "run_id" => item.run_id,
              "status" => "pending",
              "error" => nil
            }
          end),
        "error" => nil
      }

      Process.put({__MODULE__, id}, queue)
      :ok
    end

    def fetch_queue(_store, id), do: {:ok, Process.get({__MODULE__, id})}

    def start_queue_item(_store, id, position) do
      update(id, fn queue ->
        item = Enum.at(queue["items"], position) |> Map.put("status", "running")

        queue
        |> put_item(position, item)
        |> Map.put("current_run_id", item["run_id"])
      end)
    end

    def complete_queue_item(_store, id, position, head) do
      update(id, fn queue ->
        item = Enum.at(queue["items"], position) |> Map.put("status", "completed")

        queue
        |> put_item(position, item)
        |> Map.put("expected_head", head)
        |> Map.put("current_position", position + 1)
        |> Map.put("current_run_id", nil)
      end)
    end

    def stop_queue_item(_store, id, position, error) do
      update(id, fn queue ->
        item =
          queue["items"]
          |> Enum.at(position)
          |> Map.put("status", "stopped")
          |> Map.put("error", error)

        queue
        |> put_item(position, item)
        |> Map.put("status", "stopped")
        |> Map.put("error", error)
      end)
    end

    def complete_queue(_store, id), do: update(id, &Map.put(&1, "status", "completed"))

    defp update(id, function) do
      Process.put({__MODULE__, id}, function.(Process.get({__MODULE__, id})))
      :ok
    end

    defp put_item(queue, position, item) do
      Map.update!(queue, "items", &List.replace_at(&1, position, item))
    end
  end

  test "runs selected tasks serially with verbose reconciliation progress" do
    project = Hancho.Project.new(temporary_directory())
    parent = self()

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 3,
               beadwork: Beadwork,
               reconciler: Reconciler,
               workflow_runner: WorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-test",
               verbose: true,
               progress: fn message ->
                 send(parent, {:progress, message})
                 :ok
               end
             )

    assert result.status == :completed
    assert result.completed_count == 3
    assert result.child_runs == ["queue-test-001", "queue-test-002", "queue-test-003"]

    assert_received {:ran, "task-1", "queue-test-001"}
    assert_received {:ran, "task-2", "queue-test-002"}
    assert_received {:ran, "task-3", "queue-test-003"}
    assert_received {:reconciled, :before, 0}
    assert_received {:reconciled, :after, 2}
    assert_received {:progress, "Reconciled before item 1: main at head-0, clean, 0 worktrees."}
    assert_received {:progress, "Queue queue-test completed 3/3 tasks."}

    events = read_events(Path.join(project.logs_path, "factory.jsonl"))
    assert Enum.any?(events, &(&1["event"] == "queue.started"))
    assert Enum.count(events, &(&1["event"] == "queue.reconciled")) == 6
    assert Enum.any?(events, &(&1["event"] == "queue.completed"))
    assert Enum.all?(events, &(&1["metadata"]["queue_id"] == "queue-test"))
  end

  test "previews task readiness from all issues when ready returns only containers" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, preview} =
             QueueRunner.preview(project, "implement", "beadwork-ready", 1,
               beadwork: ContainerReadyBeadwork
             )

    assert preview.issues == [%{"id" => "task-next", "status" => "open"}]
    refute File.exists?(project.bedrock_path)
  end

  test "stops on the first failed child and leaves later items pending" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 3,
               beadwork: Beadwork,
               reconciler: Reconciler,
               workflow_runner: StoppingWorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-stop",
               log: :disabled
             )

    assert result.status == :stopped
    assert result.completed_count == 1
    assert result.current_issue == "task-2"
    refute_received {:ran, "task-3", _run_id}

    assert {:ok, queue} = MemoryStore.fetch_queue(:memory, "queue-stop")
    assert Enum.map(queue["items"], & &1["status"]) == ["completed", "stopped", "pending"]
  end

  test "stops before a child when reconciliation fails" do
    project = Hancho.Project.new(temporary_directory())

    assert {:ok, result} =
             QueueRunner.run(project, "implement", "beadwork-ready", 1,
               beadwork: Beadwork,
               reconciler: MismatchReconciler,
               workflow_runner: WorkflowRunner,
               store_api: MemoryStore,
               queue_id: "queue-mismatch",
               log: :disabled
             )

    assert result.status == :stopped
    assert result.error.code == "filesystem_out_of_sync"
    refute_received {:ran, _issue_id, _run_id}

    assert {:ok, queue} = MemoryStore.fetch_queue(:memory, "queue-mismatch")
    assert queue["status"] == "stopped"
    assert hd(queue["items"])["status"] == "stopped"
  end

  test "persists queue progress in Bedrock" do
    project = Hancho.Project.new(temporary_directory())
    items = [%{position: 0, issue_id: "task-1", run_id: "queue-state-001"}]
    state = %{repository: project.root, branch: "main", head: "head-0"}

    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Store.create_queue(store, "queue-state", "implement", "beadwork-ready", items, state)

    assert :ok = Store.start_queue_item(store, "queue-state", 0)
    assert :ok = Store.complete_queue_item(store, "queue-state", 0, "head-1")
    assert :ok = Store.complete_queue(store, "queue-state")
    assert :ok = Store.close(store)

    assert {:ok, reopened} = Store.open(project.bedrock_path)
    assert {:ok, queue} = Store.fetch_queue(reopened, "queue-state")
    assert queue["status"] == "completed"
    assert queue["expected_head"] == "head-1"
    assert Enum.map(queue["items"], & &1["status"]) == ["completed"]
    Store.close(reopened)
  end

  test "reconciles real Git and worktree state and reports exact mismatches" do
    repository = temporary_repository()
    {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.worktrees_path)

    assert {:ok, initial} = QueueReconciler.initial(project)
    queue = %{"expected_branch" => initial.branch, "expected_head" => initial.head}
    assert {:ok, %{worktrees: []}} = QueueReconciler.before_item(project, queue)

    unexpected = Path.join(project.worktrees_path, "unexpected")
    File.mkdir_p!(unexpected)

    assert {:error,
            %{
              code: "filesystem_out_of_sync",
              field: "worktree_directories",
              expected: [],
              actual: [^unexpected]
            }} = QueueReconciler.before_item(project, queue)
  end

  test "reconciles a retained stopped-run worktree against durable outputs" do
    repository = temporary_repository()
    {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(root)
    File.mkdir_p!(project.worktrees_path)
    assert {:ok, initial} = QueueReconciler.initial(project)
    queue = %{"expected_branch" => initial.branch, "expected_head" => initial.head}
    path = Path.join(project.worktrees_path, "queue-real-001")

    assert {:ok, :done} = Hancho.Git.create_worktree(root, path, initial.head)

    outputs = %{
      "create_worktree" => %{"worktree_path" => path, "baseline" => initial.head}
    }

    assert {:ok, %{worktrees: [^path]}} = QueueReconciler.after_run(project, queue, outputs)

    File.rm_rf!(path)

    assert {:error, %{code: "filesystem_out_of_sync", field: "worktree_directories"}} =
             QueueReconciler.after_run(project, queue, outputs)
  end

  test "stops reconciliation when the main repository becomes dirty" do
    repository = temporary_repository()
    {:ok, root} = Hancho.Git.repository_root(working_dir: repository)
    project = Hancho.Project.new(root)
    assert {:ok, initial} = QueueReconciler.initial(project)
    queue = %{"expected_branch" => initial.branch, "expected_head" => initial.head}
    File.write!(Path.join(root, "unexpected.txt"), "changed\n")

    assert {:error,
            %{
              code: "filesystem_out_of_sync",
              field: "repository_status",
              expected: "clean"
            }} = QueueReconciler.before_item(project, queue)
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-queue-#{System.unique_integer([:positive])}")
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
    {_output, 0} = System.cmd("git", ["-C", path, "add", ".gitignore"])

    {_output, 0} =
      System.cmd("git", [
        "-C",
        path,
        "-c",
        "user.name=Hancho Test",
        "-c",
        "user.email=hancho@example.test",
        "commit",
        "-m",
        "chore: initialize repository"
      ])

    path
  end

  defp read_events(path) do
    path
    |> File.stream!()
    |> Enum.map(&Jason.decode!/1)
  end
end
