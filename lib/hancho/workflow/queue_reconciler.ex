defmodule Hancho.Workflow.QueueReconciler do
  @moduledoc "Checks durable queue expectations against local Git and worktree state."

  @spec initial(Hancho.Project.t(), keyword()) :: {:ok, map()} | {:error, map() | term()}
  def initial(project, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)

    with {:ok, status} <- git.status(working_dir: project.root),
         :ok <- attached(status),
         :ok <- clean(status, "repository_status"),
         {:ok, head} <- git.head(working_dir: project.root),
         {:ok, worktrees} <- discover_worktrees(project, git),
         {:ok, summary} <-
           check(project, status.branch, head, worktrees, git) do
      {:ok,
       Map.merge(summary, %{
         repository: project.root,
         branch: status.branch,
         head: head,
         expected_worktrees: worktrees
       })}
    end
  end

  @spec before_item(Hancho.Project.t(), map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def before_item(project, queue, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)

    check(
      project,
      queue["expected_branch"],
      queue["expected_head"],
      queue_worktrees(queue),
      git
    )
  end

  @spec after_run(Hancho.Project.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def after_run(project, queue, outputs, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)
    expected_head = get_in(outputs, ["land", "commit"]) || queue["expected_head"]
    expected_worktrees = queue_worktrees(queue) ++ run_worktrees(outputs)

    check(project, queue["expected_branch"], expected_head, expected_worktrees, git)
  end

  defp check(project, expected_branch, expected_head, expected_worktrees, git) do
    expected_paths = expected_worktrees |> Enum.map(& &1.path) |> Enum.sort()

    with {:ok, status} <- git.status(working_dir: project.root),
         :ok <- clean(status, "repository_status"),
         :ok <- equal("branch", expected_branch, status.branch),
         {:ok, head} <- git.head(working_dir: project.root),
         :ok <- equal("head", expected_head, head),
         {:ok, filesystem_paths} <- filesystem_paths(project.worktrees_path),
         :ok <- equal("worktree_directories", expected_paths, filesystem_paths),
         {:ok, registered} <- registered_worktrees(git, project),
         registered_paths = registered |> Map.keys() |> Enum.sort(),
         :ok <- equal("worktree_registrations", expected_paths, registered_paths),
         :ok <- check_expected_worktrees(expected_worktrees, registered, git) do
      {:ok,
       %{
         branch: status.branch,
         head: head,
         clean: true,
         worktrees: expected_paths
       }}
    end
  end

  defp run_worktrees(outputs) do
    created = outputs["create_worktree"]
    removed = outputs["remove_worktree"]
    committed = outputs["commit"]

    if created && !removed do
      [
        %{
          path: created["worktree_path"],
          head: if(committed, do: committed["commit"], else: created["baseline"]),
          clean: not is_nil(committed)
        }
      ]
    else
      []
    end
  end

  defp queue_worktrees(queue) do
    queue
    |> Map.get("expected_worktrees", [])
    |> Enum.map(fn worktree ->
      %{
        path: worktree["path"] || worktree[:path],
        head: worktree["head"] || worktree[:head],
        clean: Map.get(worktree, "clean", Map.get(worktree, :clean, false))
      }
    end)
  end

  defp discover_worktrees(project, git) do
    with {:ok, filesystem_paths} <- filesystem_paths(project.worktrees_path),
         {:ok, registered} <- registered_worktrees(git, project),
         registered_paths = registered |> Map.keys() |> Enum.sort(),
         :ok <- equal("worktree_registrations", filesystem_paths, registered_paths) do
      Enum.reduce_while(filesystem_paths, {:ok, []}, fn path, {:ok, worktrees} ->
        registration = Map.fetch!(registered, path)

        case git.status(working_dir: path) do
          {:ok, status} ->
            worktree = %{path: path, head: registration.head, clean: status.entries == []}
            {:cont, {:ok, [worktree | worktrees]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, worktrees} -> {:ok, Enum.reverse(worktrees)}
        error -> error
      end
    end
  end

  defp check_expected_worktrees(expected, registered, git) do
    Enum.reduce_while(expected, :ok, fn worktree, :ok ->
      registration = Map.fetch!(registered, worktree.path)

      with :ok <- equal("worktree_type", true, File.dir?(worktree.path)),
           :ok <- equal("worktree_head", worktree.head, registration.head),
           :ok <- equal("worktree_detached", true, registration.detached),
           :ok <- equal("worktree_prunable", nil, registration.prunable),
           :ok <- maybe_clean_worktree(worktree, git) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, with_path(reason, worktree.path)}}
        other -> {:halt, other}
      end
    end)
  end

  defp maybe_clean_worktree(%{clean: false}, _git), do: :ok

  defp maybe_clean_worktree(%{clean: true, path: path}, git) do
    with {:ok, status} <- git.status(working_dir: path) do
      clean(status, "worktree_status")
    end
  end

  defp filesystem_paths(root) do
    case File.ls(root) do
      {:ok, entries} ->
        {:ok, entries |> Enum.map(&Path.expand(&1, root)) |> Enum.sort()}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp registered_worktrees(git, project) do
    with {:ok, worktrees} <- git.worktrees(working_dir: project.root) do
      registered =
        worktrees
        |> Enum.filter(&under_root?(&1.path, project.worktrees_path))
        |> Map.new(&{Path.expand(&1.path), &1})

      {:ok, registered}
    end
  end

  defp under_root?(path, root) do
    root = Path.expand(root)
    relative = path |> Path.expand() |> Path.relative_to(root)

    case Path.safe_relative(relative, root) do
      {:ok, relative} -> relative != "."
      :error -> false
    end
  end

  defp attached(%Git.Status{branch: branch}) when branch not in [nil, "HEAD (no branch)"], do: :ok
  defp attached(_status), do: mismatch("branch", "attached branch", "detached HEAD")

  defp clean(%Git.Status{entries: []}, _field), do: :ok
  defp clean(%Git.Status{entries: entries}, field), do: mismatch(field, "clean", entries)

  defp equal(_field, value, value), do: :ok
  defp equal(field, expected, actual), do: mismatch(field, expected, actual)

  defp mismatch(field, expected, actual) do
    {:error,
     %{
       code: "filesystem_out_of_sync",
       field: field,
       expected: expected,
       actual: Hancho.Log.Event.normalize(actual)
     }}
  end

  defp with_path(reason, path), do: Map.put(reason, :path, path)
end
