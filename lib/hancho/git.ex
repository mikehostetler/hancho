defmodule Hancho.Git do
  @moduledoc "Git safety operations that remain under Hancho control."

  alias Hancho.{Error, Repository, SQLite, Store}

  @spec preflight(Repository.t()) :: {:ok, map()} | {:error, Error.t()}
  def preflight(repository) do
    with {:ok, status} <-
           command(repository.root, ["status", "--porcelain=v1", "--untracked-files=all"]),
         :ok <- require_clean(status),
         branch when is_binary(branch) <- repository.branch,
         {:ok, baseline} <- command(repository.root, ["rev-parse", "HEAD"]) do
      {:ok, %{baseline: baseline, branch: branch}}
    else
      nil -> error(:detached_head, "Detached HEAD is not supported for Build.V1.")
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec prepare_worktree(Repository.t(), String.t(), String.t()) ::
          {:ok, Path.t()} | {:error, Error.t()}
  def prepare_worktree(repository, run_id, baseline) do
    path = Path.join([repository.runtime_dir, "tmp", "worktrees", run_id])
    File.mkdir_p!(Path.dirname(path))

    with {:ok, _output} <-
           command(repository.root, ["worktree", "add", "--detach", path, baseline]),
         :ok <- update_worktree_path(repository, run_id, path) do
      {:ok, path}
    end
  end

  @spec remove_worktree(Repository.t(), Path.t()) :: :ok | {:error, Error.t()}
  def remove_worktree(repository, path) do
    boundary = Path.expand(Path.join(repository.runtime_dir, "tmp/worktrees")) <> "/"

    if String.starts_with?(Path.expand(path), boundary) do
      case command(repository.root, ["worktree", "remove", "--force", path]) do
        {:ok, _} -> :ok
        {:error, error} -> {:error, error}
      end
    else
      error(:unsafe_worktree_path, "Refusing to remove worktree outside '#{boundary}'.")
    end
  end

  @spec changed_paths(Path.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def changed_paths(worktree) do
    with {:ok, output} <-
           command(worktree, ["status", "--porcelain=v1", "-z", "--untracked-files=all"],
             trim: false
           ) do
      {:ok, parse_porcelain(output)}
    end
  end

  @spec worktree_fingerprint(Path.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def worktree_fingerprint(worktree) do
    with {:ok, diff} <- command(worktree, ["diff", "--binary", "HEAD"], trim: false),
         {:ok, untracked} <-
           command(worktree, ["ls-files", "--others", "--exclude-standard", "-z"], trim: false) do
      extra =
        untracked
        |> String.split(<<0>>, trim: true)
        |> Enum.sort()
        |> Enum.map(fn path ->
          full = Path.join(worktree, path)
          data = if File.regular?(full), do: File.read!(full), else: "[non-regular]"
          [path, <<0>>, data, <<0>>]
        end)

      hash = :crypto.hash(:sha256, [diff | extra]) |> Base.encode16(case: :lower)
      {:ok, hash}
    end
  rescue
    failure -> error(:worktree_fingerprint_failed, Exception.message(failure))
  end

  @spec verify_scope([String.t()], [String.t()]) :: :ok | {:error, Error.t()}
  def verify_scope([], _allowed_scopes),
    do: error(:no_changes, "The harness made no source change.")

  def verify_scope(paths, allowed_scopes) do
    outside = Enum.reject(paths, &allowed?(&1, allowed_scopes))

    if outside == [] do
      :ok
    else
      error(
        :scope_violation,
        "Changed paths are outside admitted scope: #{Enum.join(outside, ", ")}.",
        %{paths: outside}
      )
    end
  end

  @spec assert_head(Path.t(), String.t()) :: :ok | {:error, Error.t()}
  def assert_head(worktree, expected) do
    with {:ok, actual} <- command(worktree, ["rev-parse", "HEAD"]) do
      if actual == expected,
        do: :ok,
        else:
          error(:harness_git_effect, "Harness changed HEAD from '#{expected}' to '#{actual}'.")
    end
  end

  @spec assert_target_unchanged(Repository.t(), String.t()) :: :ok | {:error, Error.t()}
  def assert_target_unchanged(repository, baseline), do: assert_head(repository.root, baseline)

  @spec create_candidate(Path.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def create_candidate(worktree, baseline, run_id, title) do
    create_candidate(worktree, baseline, run_id, title, run_id)
  end

  @spec create_candidate(Path.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def create_candidate(worktree, baseline, run_id, title, work_ref) do
    with {:ok, _} <- command(worktree, ["add", "-A"]),
         {:ok, _} <-
           command(worktree, [
             "commit",
             "-m",
             "#{title}\n\nHancho-Work-Order: #{run_id}\nHancho-Work-Reference: #{work_ref}"
           ]),
         {:ok, commit} <- command(worktree, ["rev-parse", "HEAD"]),
         {:ok, parent} <- command(worktree, ["rev-parse", "#{commit}^"]),
         true <- parent == baseline,
         {:ok, _} <- command(worktree, ["diff", "--check", "#{baseline}..#{commit}"]) do
      {:ok, commit}
    else
      false ->
        error(
          :candidate_contract_failed,
          "Candidate commit does not have the pinned baseline as its only parent."
        )

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  @spec undo_candidate(Path.t(), String.t()) :: :ok | {:error, Error.t()}
  def undo_candidate(worktree, baseline) do
    case command(worktree, ["reset", "--soft", baseline]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec changed_paths_between(Path.t(), String.t(), String.t()) ::
          {:ok, [String.t()]} | {:error, Error.t()}
  def changed_paths_between(worktree, baseline, commit) do
    with {:ok, output} <-
           command(worktree, ["diff", "--name-only", "-z", "#{baseline}..#{commit}"], trim: false) do
      {:ok, String.split(output, <<0>>, trim: true)}
    end
  end

  @spec retain_candidate(Repository.t(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def retain_candidate(repository, run_id, commit) do
    case command(repository.root, ["update-ref", "refs/hancho/candidates/#{run_id}", commit]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @spec command(Path.t(), [String.t()], keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def command(path, args, options \\ []) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, if(Keyword.get(options, :trim, true), do: String.trim(output), else: output)}

      {output, status} ->
        error(:git_failed, "Git command failed with status #{status}: #{String.trim(output)}", %{
          args: args,
          status: status
        })
    end
  rescue
    error -> error(:git_failed, "Cannot run Git: #{Exception.message(error)}")
  end

  defp require_clean(""), do: :ok

  defp require_clean(status),
    do: error(:dirty_control_checkout, "The control checkout is not clean:\n#{status}")

  defp allowed?(path, scopes) do
    Enum.any?(scopes, fn scope ->
      if String.ends_with?(scope, "/"), do: String.starts_with?(path, scope), else: path == scope
    end)
  end

  defp parse_porcelain(output),
    do: parse_entries(String.split(output, <<0>>, trim: true), []) |> Enum.uniq()

  defp parse_entries([], paths), do: Enum.reverse(paths)

  defp parse_entries([entry, source | rest], paths)
       when binary_part(entry, 0, 2) in ["R ", " R", "C ", " C"] do
    destination = binary_part(entry, 3, byte_size(entry) - 3)
    parse_entries(rest, [source, destination | paths])
  end

  defp parse_entries([entry | rest], paths) do
    path = if byte_size(entry) >= 4, do: binary_part(entry, 3, byte_size(entry) - 3), else: entry
    parse_entries(rest, [path | paths])
  end

  defp update_worktree_path(repository, run_id, path) do
    SQLite.execute(
      Store.path(repository),
      "UPDATE work_orders SET worktree_path = #{SQLite.quote(path)} WHERE id = #{SQLite.quote(run_id)};"
    )
  end

  defp error(code, message, details \\ nil),
    do: {:error, %Error{code: code, exit_status: 75, message: message, details: details}}
end
