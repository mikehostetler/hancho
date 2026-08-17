defmodule Hancho.Worktrees do
  @moduledoc "Inspects and cleans retained Hancho worktrees."

  @generated_directories ["_build", "deps", "cover"]

  @spec list(Hancho.Project.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(project, options \\ []) do
    case File.ls(project.worktrees_path) do
      {:ok, entries} ->
        reports =
          entries
          |> Enum.sort()
          |> Enum.map(fn id ->
            case inspect(project, id, options) do
              {:ok, report} ->
                report

              {:error, reason} ->
                %{id: id, path: Path.join(project.worktrees_path, id), error: reason}
            end
          end)

        {:ok, reports}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec inspect(Hancho.Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def inspect(project, id, options \\ []) do
    git = Keyword.get(options, :git, Hancho.Git)

    with {:ok, path} <- resolve(project, id),
         {:ok, registrations} <- git.worktrees(working_dir: project.root),
         registration = Enum.find(registrations, &same_path?(&1.path, path)),
         {:ok, status} <- git.status(working_dir: path, untracked_files: :all) do
      generated = generated_sizes(path)

      {:ok,
       %{
         id: id,
         path: path,
         registered: not is_nil(registration),
         detached: registration && registration.detached,
         head: registration && registration.head,
         clean: status.entries == [],
         changed_paths: status.entries |> Enum.map(& &1.path) |> Enum.sort(),
         size_bytes: disk_size(path),
         generated_bytes: generated |> Map.values() |> Enum.sum(),
         generated: generated
       }}
    end
  end

  @spec clean(Hancho.Project.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def clean(project, id, options \\ []) do
    with {:ok, report} <- inspect(project, id, options),
         :ok <- registered(report),
         {:ok, removed} <- remove_generated(report.path) do
      {:ok,
       %{
         id: id,
         path: report.path,
         removed: removed,
         reclaimed_bytes: report.generated_bytes,
         source_changes_retained: true
       }}
    end
  end

  defp resolve(project, id) do
    cond do
      id in ["", ".", ".."] ->
        {:error, :invalid_worktree_id}

      Path.basename(id) != id ->
        {:error, :invalid_worktree_id}

      true ->
        path = Path.expand(id, project.worktrees_path)

        if File.dir?(path) do
          {:ok, path}
        else
          {:error, :worktree_not_found}
        end
    end
  end

  defp registered(%{registered: true}), do: :ok
  defp registered(_report), do: {:error, :worktree_not_registered}

  defp generated_sizes(path) do
    Map.new(@generated_directories, fn name ->
      {name, disk_size(Path.join(path, name))}
    end)
  end

  defp remove_generated(path) do
    Enum.reduce_while(@generated_directories, {:ok, []}, fn name, {:ok, removed} ->
      target = Path.join(path, name)

      if match?({:ok, _stat}, File.lstat(target)) do
        case File.rm_rf(target) do
          {:ok, _paths} ->
            {:cont, {:ok, [name | removed]}}

          {:error, reason, failed_path} ->
            {:halt, {:error, {:remove_failed, failed_path, reason}}}
        end
      else
        {:cont, {:ok, removed}}
      end
    end)
    |> case do
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      error -> error
    end
  end

  defp disk_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(path) do
          {:ok, entries} -> Enum.reduce(entries, 0, &(&2 + disk_size(Path.join(path, &1))))
          {:error, _reason} -> 0
        end

      _other ->
        0
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
end
