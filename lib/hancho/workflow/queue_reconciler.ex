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
           check(project, status.branch, head, worktrees, git, :clean) do
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
      git,
      :clean
    )
  end

  @spec after_run(Hancho.Project.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def after_run(project, queue, artifacts, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)
    expected_head = get_in(artifacts, ["landing", "commit"]) || queue["expected_head"]
    expected_worktrees = queue_worktrees(queue) ++ run_worktrees(artifacts)

    check(project, queue["expected_branch"], expected_head, expected_worktrees, git, :clean)
  end

  @spec after_stopped_run(Hancho.Project.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, map() | term()}
  def after_stopped_run(project, queue, artifacts, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)
    expected_worktrees = queue_worktrees(queue) ++ run_worktrees(artifacts)

    with {:ok, mode} <- workspace_mode(project, artifacts) do
      expected_heads = stopped_repository_heads(mode, queue, artifacts)

      cleanliness =
        if mode == :in_place and is_nil(artifacts["commit"]), do: :allow_dirty, else: :clean

      check(
        project,
        queue["expected_branch"],
        expected_heads,
        expected_worktrees,
        git,
        cleanliness
      )
    end
  end

  defp check(project, expected_branch, expected_head, expected_worktrees, git, cleanliness) do
    expected_paths = expected_worktrees |> Enum.map(& &1.path) |> Enum.sort()

    with {:ok, status} <- git.status(working_dir: project.root),
         :ok <- repository_status(status, cleanliness),
         :ok <- equal("branch", expected_branch, status.branch),
         {:ok, head} <- git.head(working_dir: project.root),
         :ok <- expected_head(expected_head, head),
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
         clean: status.entries == [],
         changed_paths: status.entries |> Enum.map(& &1.path) |> Enum.sort(),
         worktrees: expected_paths
       }}
    end
  end

  defp workspace_mode(project, %{
         "workspace_opened" => %{"mode" => "in_place", "workspace_path" => path}
       }) do
    if Path.expand(path) == Path.expand(project.root) do
      {:ok, :in_place}
    else
      mismatch("workspace_path", Path.expand(project.root), Path.expand(path))
    end
  end

  defp workspace_mode(_project, _artifacts), do: {:ok, :worktree}

  defp stopped_repository_heads(:in_place, queue, artifacts) do
    expected =
      get_in(artifacts, ["landing", "commit"]) ||
        get_in(artifacts, ["commit", "commit"]) ||
        queue["expected_head"]

    [expected]
  end

  defp stopped_repository_heads(:worktree, queue, artifacts) do
    case get_in(artifacts, ["landing", "commit"]) do
      landed when is_binary(landed) ->
        [landed]

      _not_landed ->
        [queue["expected_head"], get_in(artifacts, ["commit", "commit"])]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  defp run_worktrees(artifacts) do
    created = artifacts["worktree_created"]
    removed = artifacts["worktree_removed"]
    committed = artifacts["commit"]

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

  defp repository_status(_status, :allow_dirty), do: :ok
  defp repository_status(status, :clean), do: clean(status, "repository_status")

  defp equal(_field, value, value), do: :ok
  defp equal(field, expected, actual), do: mismatch(field, expected, actual)

  defp expected_head(expected, actual) when is_list(expected) do
    if actual in expected do
      :ok
    else
      case expected do
        [one] -> mismatch("head", one, actual)
        many -> mismatch("head", many, actual)
      end
    end
  end

  defp expected_head(expected, actual), do: equal("head", expected, actual)

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
