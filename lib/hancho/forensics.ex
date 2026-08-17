defmodule Hancho.Forensics do
  @moduledoc "Writes private, repository-local failure reports for later diagnosis."

  alias Hancho.Workflow.Result

  @schema_version 1

  @spec capture_run(Hancho.Project.t(), Result.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def capture_run(project, %Result{status: :stopped} = result, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)

    report = %{
      schema_version: @schema_version,
      kind: "workflow_failure",
      captured_at: timestamp(),
      run: %{
        id: result.run_id,
        workflow: result.workflow,
        status: result.status,
        current_step: result.current_step,
        error: result.error
      },
      repository: git_snapshot(project.root, git),
      workspace: workspace_snapshot(project, result.artifacts, git),
      artifacts: result.artifacts,
      cleanup: result.cleanup
    }

    write_report(project, "runs", result.run_id, report)
  end

  @spec capture_queue(Hancho.Project.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def capture_queue(project, details, options \\ []) when is_map(details) do
    git = Keyword.get(options, :git, Hancho.Git)

    report = %{
      schema_version: @schema_version,
      kind: "queue_failure",
      captured_at: timestamp(),
      queue: %{
        id: fetch(details, :queue_id),
        workflow: fetch(details, :workflow),
        issue_id: fetch(details, :issue_id),
        child_run_id: fetch(details, :child_run_id),
        position: fetch(details, :position),
        total_count: fetch(details, :total_count),
        error: fetch(details, :error)
      },
      repository: git_snapshot(project.root, git),
      child_forensic_report: fetch(details, :child_forensic_report)
    }

    write_report(project, "queues", fetch(details, :queue_id), report)
  end

  @spec run_report_path(Hancho.Project.t(), String.t()) :: String.t()
  def run_report_path(project, run_id) do
    report_path(project, "runs", run_id)
  end

  defp workspace_snapshot(project, artifacts, git) do
    cond do
      workspace = artifacts["workspace_opened"] ->
        workspace
        |> Map.put_new("mode", "in_place")
        |> Map.put("git", git_snapshot(workspace["workspace_path"] || project.root, git))

      workspace = retained_worktree(artifacts) ->
        workspace
        |> Map.put_new("mode", "worktree")
        |> Map.put("git", git_snapshot(workspace["worktree_path"], git))

      true ->
        nil
    end
  end

  defp retained_worktree(artifacts) do
    case {artifacts["worktree_created"], artifacts["worktree_removed"]} do
      {%{} = workspace, nil} -> workspace
      _other -> nil
    end
  end

  defp git_snapshot(path, git) when is_binary(path) do
    status = git.status(working_dir: path, untracked_files: :all)
    head = git.head(working_dir: path)

    case status do
      {:ok, value} ->
        %{
          path: Path.expand(path),
          exists: File.dir?(path),
          branch: value.branch,
          head: value_or_error(head),
          clean: value.entries == [],
          status: Enum.map(value.entries, &status_entry/1)
        }

      {:error, reason} ->
        %{
          path: Path.expand(path),
          exists: File.dir?(path),
          head: value_or_error(head),
          error: Hancho.Log.Event.normalize(reason)
        }
    end
  rescue
    error ->
      %{
        path: Path.expand(path),
        exists: File.dir?(path),
        error: Hancho.Log.Event.normalize({:exception, error})
      }
  catch
    kind, reason ->
      %{
        path: Path.expand(path),
        exists: File.dir?(path),
        error: Hancho.Log.Event.normalize({kind, reason})
      }
  end

  defp git_snapshot(path, _git), do: %{path: path, exists: false, error: "invalid_path"}

  defp status_entry(entry) do
    %{
      index: Map.get(entry, :index),
      working_tree: Map.get(entry, :working_tree),
      path: Map.get(entry, :path)
    }
  end

  defp value_or_error({:ok, value}), do: value
  defp value_or_error({:error, reason}), do: %{error: Hancho.Log.Event.normalize(reason)}

  defp write_report(project, category, id, report) do
    path = report_path(project, category, id)
    directory = Path.dirname(path)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
    contents = Jason.encode_to_iodata!(Hancho.Log.Event.normalize(report), pretty: true)

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- File.chmod(project.hancho_dir, 0o700),
           :ok <- File.chmod(project.forensics_path, 0o700),
           :ok <- File.chmod(directory, 0o700),
           :ok <- File.write(temporary, [contents, "\n"], [:binary]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path) do
        {:ok, path}
      end

    if match?({:error, _reason}, result), do: File.rm(temporary)
    result
  rescue
    error -> {:error, {:exception, error}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp report_path(project, category, id) do
    project.forensics_path
    |> Path.join(category)
    |> Path.join(safe_filename(id) <> ".json")
  end

  defp safe_filename(id) when is_binary(id) do
    if id not in ["", ".", ".."] and Path.basename(id) == id do
      id
    else
      Base.url_encode64(id, padding: false)
    end
  end

  defp safe_filename(id), do: id |> inspect() |> Base.url_encode64(padding: false)

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp timestamp do
    DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end
end
