defmodule Hancho.Workflow.RunReconciler do
  @moduledoc "Checks saved Git state before a stopped workflow runs again."

  alias Hancho.Workflow.{Artifacts, QueueReconciler}

  @spec retry(Hancho.Project.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def retry(project, outputs, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)
    definition = Keyword.fetch!(options, :definition)
    artifacts = Artifacts.from_outputs(definition, outputs)

    case Artifacts.fetch(artifacts, "repository") do
      nil ->
        QueueReconciler.initial(project, options)

      preflight ->
        with {:ok, mode} <- workspace_mode(project, artifacts),
             expected_heads = expected_repository_heads(mode, artifacts, preflight),
             {:ok, status} <- git.status(working_dir: project.root, untracked_files: :all),
             :ok <- repository_status(status, mode, artifacts),
             :ok <- equal("branch", preflight["branch"], status.branch),
             {:ok, head} <- git.head(working_dir: project.root),
             :ok <- one_of("head", expected_heads, head),
             :ok <- check_worktree(project, artifacts, git) do
          {:ok,
           %{
             branch: status.branch,
             head: head,
             clean: status.entries == [],
             changed_paths: status.entries |> Enum.map(& &1.path) |> Enum.sort()
           }}
        end
    end
  end

  defp check_worktree(
         _project,
         %{"worktree_created" => _created, "worktree_removed" => _removed},
         _git
       ),
       do: :ok

  defp check_worktree(project, %{"worktree_created" => created} = artifacts, git) do
    path = Path.expand(created["worktree_path"])
    expected_head = get_in(artifacts, ["commit", "commit"]) || created["baseline"]

    with :ok <- under_root(path, project.worktrees_path),
         :ok <- equal("worktree_directory", true, File.dir?(path)),
         {:ok, registrations} <- git.worktrees(working_dir: project.root),
         {:ok, registration} <- find_registration(registrations, path),
         :ok <- equal("worktree_head", expected_head, registration.head),
         :ok <- equal("worktree_detached", true, registration.detached),
         {:ok, status} <- git.status(working_dir: path),
         :ok <- committed_worktree_clean(artifacts, status) do
      :ok
    else
      {:error, reason} -> {:error, with_path(reason, path)}
      other -> other
    end
  end

  defp check_worktree(_project, _outputs, _git), do: :ok

  defp workspace_mode(project, %{
         "workspace_opened" => %{"mode" => "in_place", "workspace_path" => path}
       }) do
    with :ok <- equal("workspace_path", Path.expand(project.root), Path.expand(path)) do
      {:ok, :in_place}
    end
  end

  defp workspace_mode(_project, _artifacts), do: {:ok, :worktree}

  defp expected_repository_heads(:in_place, artifacts, preflight) do
    expected =
      get_in(artifacts, ["landing", "commit"]) ||
        get_in(artifacts, ["commit", "commit"]) ||
        preflight["baseline"]

    [expected]
  end

  defp expected_repository_heads(:worktree, artifacts, preflight) do
    case get_in(artifacts, ["landing", "commit"]) do
      landed when is_binary(landed) ->
        [landed]

      _not_landed ->
        [preflight["baseline"], get_in(artifacts, ["commit", "commit"])]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  defp repository_status(_status, :in_place, artifacts)
       when not is_map_key(artifacts, "commit") and not is_map_key(artifacts, "landing"),
       do: :ok

  defp repository_status(status, _mode, _artifacts),
    do: equal("repository_status", [], status.entries)

  defp committed_worktree_clean(%{"commit" => _commit}, status),
    do: equal("worktree_status", [], status.entries)

  defp committed_worktree_clean(_outputs, _status), do: :ok

  defp find_registration(registrations, path) do
    case Enum.find(registrations, &same_path?(&1.path, path)) do
      nil ->
        mismatch(
          "worktree_registration",
          Path.expand(path),
          Enum.map(registrations, &Path.expand(&1.path))
        )

      registration ->
        {:ok, registration}
    end
  end

  defp same_path?(left, right) do
    if Path.expand(left) == Path.expand(right) do
      true
    else
      with {:ok, left_stat} <- File.stat(left),
           {:ok, right_stat} <- File.stat(right) do
        left_stat.inode == right_stat.inode and
          left_stat.major_device == right_stat.major_device and
          left_stat.minor_device == right_stat.minor_device
      else
        _error -> false
      end
    end
  end

  defp under_root(path, root) do
    root = Path.expand(root)
    relative = Path.relative_to(path, root)

    case Path.safe_relative(relative, root) do
      {:ok, "."} -> mismatch("worktree_path", "child of #{root}", path)
      {:ok, _relative} -> :ok
      :error -> mismatch("worktree_path", "child of #{root}", path)
    end
  end

  defp equal(_field, value, value), do: :ok
  defp equal(field, expected, actual), do: mismatch(field, expected, actual)

  defp one_of(field, expected, actual) do
    if actual in expected do
      :ok
    else
      case expected do
        [one] -> mismatch(field, one, actual)
        many -> mismatch(field, many, actual)
      end
    end
  end

  defp mismatch(field, expected, actual) do
    {:error,
     %{
       code: "filesystem_out_of_sync",
       field: field,
       expected: expected,
       actual: Hancho.Log.Event.normalize(actual)
     }}
  end

  defp with_path(%{} = reason, path), do: Map.put(reason, :path, path)
  defp with_path(reason, path), do: %{code: "filesystem_check_failed", error: reason, path: path}
end
