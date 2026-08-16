defmodule Hancho.Cleanup do
  @moduledoc "Plans retention cleanup by default and records every applied artifact removal."

  alias Hancho.{Clock, Config, Error, Git, ID, Repository, SQLite, Store}

  @spec run(Repository.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run(repository, options \\ []) do
    apply? = Keyword.get(options, :apply, false)
    now = Keyword.get(options, :now, DateTime.utc_now())

    with {:ok, config} <- Config.load(repository),
         {:ok, artifacts} <- artifact_candidates(repository, config, now),
         {:ok, worktrees} <- worktree_candidates(repository, config, now),
         {:ok, removed} <- maybe_apply(repository, artifacts, worktrees, apply?, options) do
      {:ok,
       %{
         mode: if(apply?, do: "applied", else: "dry_run"),
         artifact_candidates: artifacts,
         worktree_candidates: worktrees,
         removed: removed
       }}
    end
  end

  @spec events(Repository.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def events(repository) do
    SQLite.query(Store.path(repository), "SELECT * FROM cleanup_events ORDER BY removed_at, id;")
  end

  defp artifact_candidates(repository, config, now) do
    query = """
    SELECT a.* FROM artifacts a
    JOIN work_orders w ON w.id = a.run_id
    WHERE w.status IN ('complete', 'cancelled')
      AND NOT EXISTS (SELECT 1 FROM effects e WHERE e.run_id = a.run_id AND e.status IN ('intent', 'uncertain'))
      AND NOT EXISTS (SELECT 1 FROM actions x WHERE x.run_id = a.run_id AND x.status IN ('requested', 'started', 'uncertain'))
    ORDER BY a.created_at, a.id;
    """

    with {:ok, artifacts} <- SQLite.query(Store.path(repository), query) do
      {:ok,
       Enum.flat_map(artifacts, fn artifact ->
         case retention_days(artifact, config) do
           nil -> []
           days -> if older?(artifact["created_at"], now, days), do: [artifact], else: []
         end
       end)}
    end
  end

  defp worktree_candidates(repository, config, now) do
    days = get_in(config.data, ["retention", "temp_worktrees_days"]) || 7

    with {:ok, work_orders} <-
           SQLite.query(
             Store.path(repository),
             "SELECT w.* FROM work_orders w WHERE w.status IN ('complete', 'cancelled') AND w.worktree_path IS NOT NULL AND NOT EXISTS (SELECT 1 FROM effects e WHERE e.run_id = w.id AND e.status IN ('intent', 'uncertain')) ORDER BY w.updated_at, w.id;"
           ) do
      {:ok,
       Enum.filter(work_orders, fn work_order ->
         is_binary(work_order["worktree_path"]) and File.dir?(work_order["worktree_path"]) and
           older?(work_order["updated_at"], now, days)
       end)}
    end
  end

  defp maybe_apply(_repository, _artifacts, _worktrees, false, _options), do: {:ok, []}

  defp maybe_apply(repository, artifacts, worktrees, true, options) do
    actor = Keyword.get(options, :actor, System.get_env("USER") || "local-user")

    with {:ok, before_facts} <- transition_fingerprint(repository),
         {:ok, removed_artifacts} <- remove_artifacts(repository, artifacts, actor),
         {:ok, removed_worktrees} <- remove_worktrees(repository, worktrees),
         :ok <- SQLite.execute(Store.path(repository), "VACUUM;"),
         {:ok, after_facts} <- transition_fingerprint(repository),
         true <- before_facts == after_facts do
      {:ok, removed_artifacts ++ removed_worktrees}
    else
      false ->
        {:error,
         error(
           :cleanup_changed_transition_facts,
           "Database compaction changed durable transition facts."
         )}

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp remove_artifacts(repository, artifacts, actor) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, removed} ->
      path = Path.expand(Path.join(repository.runtime_dir, artifact["relative_path"]))
      boundary = Path.expand(repository.runtime_dir) <> "/"

      cond do
        not String.starts_with?(path, boundary) ->
          {:halt,
           {:error, error(:cleanup_path_escape, "Cleanup path escapes the runtime directory.")}}

        true ->
          case File.rm(path) do
            :ok ->
              case record_removal(repository, artifact, actor) do
                :ok ->
                  {:cont,
                   {:ok, [%{type: "artifact", path: path, artifact_id: artifact["id"]} | removed]}}

                {:error, failure} ->
                  {:halt, {:error, failure}}
              end

            {:error, :enoent} ->
              case record_removal(repository, artifact, actor) do
                :ok ->
                  {:cont,
                   {:ok,
                    [
                      %{type: "artifact_absent", path: path, artifact_id: artifact["id"]}
                      | removed
                    ]}}

                {:error, failure} ->
                  {:halt, {:error, failure}}
              end

            {:error, reason} ->
              {:halt,
               {:error,
                error(
                  :cleanup_remove_failed,
                  "Cannot remove '#{path}': #{:file.format_error(reason)}"
                )}}
          end
      end
    end)
  end

  defp remove_worktrees(repository, worktrees) do
    Enum.reduce_while(worktrees, {:ok, []}, fn work_order, {:ok, removed} ->
      case Git.remove_worktree(repository, work_order["worktree_path"]) do
        :ok ->
          {:cont,
           {:ok,
            [
              %{type: "worktree", path: work_order["worktree_path"], run_id: work_order["id"]}
              | removed
            ]}}

        {:error, failure} ->
          {:halt, {:error, failure}}
      end
    end)
  end

  defp record_removal(repository, artifact, actor) do
    SQLite.execute(
      Store.path(repository),
      "INSERT INTO cleanup_events (id, artifact_id, run_id, relative_path, content_hash, byte_size, reason, actor, removed_at) VALUES (#{q(ID.generate("cleanup"))}, #{q(artifact["id"])}, #{q(artifact["run_id"])}, #{q(artifact["relative_path"])}, #{q(artifact["content_hash"])}, #{q(artifact["byte_size"])}, 'retention_policy', #{q(actor)}, #{q(Clock.utc_now())});"
    )
  end

  defp transition_fingerprint(repository) do
    SQLite.scalar(
      Store.path(repository),
      "SELECT CAST(COUNT(*) AS TEXT) || ':' || CAST(COALESCE(MAX(id), 0) AS TEXT) || ':' || CAST(COALESCE(SUM(seq), 0) AS TEXT) FROM events;"
    )
  end

  defp retention_days(%{"retention_class" => "sensitive_raw"}, config),
    do: get_in(config.data, ["retention", "raw_logs_days"]) || 7

  defp retention_days(%{"kind" => "prompt"}, config),
    do: get_in(config.data, ["retention", "prompts_days"]) || 30

  defp retention_days(%{"kind" => "check"}, config),
    do: get_in(config.data, ["retention", "checks_days"]) || 30

  defp retention_days(%{"kind" => kind}, config) when kind in ["report", "audit_report"],
    do: get_in(config.data, ["retention", "reports_days"]) || 365

  defp retention_days(_artifact, _config), do: nil

  defp older?(iso8601, now, days) do
    with {:ok, created, _offset} <- DateTime.from_iso8601(iso8601) do
      DateTime.compare(created, DateTime.add(now, -days * 86_400, :second)) in [:lt, :eq]
    else
      _ -> false
    end
  end

  defp q(value), do: SQLite.quote(value)
  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
