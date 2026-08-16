defmodule Hancho.Store do
  @moduledoc "SQLite schema and low-level durable state operations."

  alias Hancho.{Error, Repository, SQLite}

  @schema_version 3

  @spec path(Repository.t()) :: Path.t()
  def path(repository), do: Path.join(repository.runtime_dir, "hancho.sqlite3")

  @spec migrate(Path.t()) :: :ok | {:error, Error.t()}
  def migrate(path) do
    with {:ok, version} <- SQLite.scalar(path, "PRAGMA user_version;") do
      cond do
        is_integer(version) and version > @schema_version ->
          newer_schema_error(version)

        version in [nil, 0] ->
          with :ok <- SQLite.execute(path, migration_v1()), do: migrate(path)

        version == 1 ->
          with :ok <- SQLite.execute(path, migration_v2()), do: migrate(path)

        version == 2 ->
          with :ok <- SQLite.execute(path, migration_v3()), do: migrate(path)

        version == @schema_version ->
          :ok

        true ->
          {:error,
           %Error{
             code: :schema_gap,
             exit_status: 78,
             message: "No migration path from schema #{version}."
           }}
      end
    end
  end

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  defp newer_schema_error(version) do
    {:error,
     %Error{
       code: :newer_database_schema,
       exit_status: 78,
       message:
         "Database schema #{version} is newer than supported schema #{@schema_version}. No data changed."
     }}
  end

  defp migration_v1 do
    """
    PRAGMA foreign_keys = ON;
    BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS repositories (
      id TEXT PRIMARY KEY,
      root TEXT NOT NULL,
      git_common_dir TEXT NOT NULL,
      remote TEXT,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS work_orders (
      id TEXT PRIMARY KEY,
      repository_id TEXT NOT NULL,
      workflow_name TEXT NOT NULL,
      workflow_version INTEGER NOT NULL,
      work_ref TEXT NOT NULL,
      state TEXT NOT NULL,
      status TEXT NOT NULL,
      config_hash TEXT NOT NULL,
      baseline_commit TEXT,
      target_branch TEXT,
      worktree_path TEXT,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id TEXT NOT NULL,
      seq INTEGER NOT NULL,
      actor TEXT NOT NULL,
      occurred_at TEXT NOT NULL,
      prior_state TEXT,
      event TEXT NOT NULL,
      result_state TEXT NOT NULL,
      reason TEXT,
      correlation_id TEXT NOT NULL,
      payload_json TEXT NOT NULL DEFAULT '{}',
      UNIQUE(run_id, seq)
    );
    CREATE TABLE IF NOT EXISTS actions (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      station TEXT NOT NULL,
      kind TEXT NOT NULL,
      status TEXT NOT NULL,
      idempotency_key TEXT NOT NULL UNIQUE,
      requested_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      result_json TEXT
    );
    CREATE TABLE IF NOT EXISTS effects (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      target TEXT NOT NULL,
      status TEXT NOT NULL,
      idempotency_key TEXT NOT NULL UNIQUE,
      intent_at TEXT NOT NULL,
      observed_at TEXT,
      observation_json TEXT
    );
    CREATE TABLE IF NOT EXISTS decisions (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      status TEXT NOT NULL,
      request_json TEXT NOT NULL,
      requested_at TEXT NOT NULL,
      actor TEXT,
      reason TEXT,
      decided_at TEXT
    );
    CREATE TABLE IF NOT EXISTS harness_sessions (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      station TEXT NOT NULL,
      adapter TEXT NOT NULL,
      harness TEXT NOT NULL,
      adapter_version TEXT,
      harness_version TEXT,
      capabilities_json TEXT NOT NULL,
      config_hash TEXT NOT NULL,
      status TEXT NOT NULL,
      started_at TEXT NOT NULL,
      finished_at TEXT
    );
    CREATE TABLE IF NOT EXISTS artifacts (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      byte_size INTEGER NOT NULL,
      media_type TEXT NOT NULL,
      retention_class TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS leases (
      name TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      acquired_at TEXT NOT NULL,
      expires_at TEXT
    );
    CREATE TABLE IF NOT EXISTS work_references (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      kind TEXT NOT NULL,
      reference TEXT NOT NULL,
      canonical INTEGER NOT NULL DEFAULT 1,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL,
      UNIQUE(run_id, kind, canonical)
    );
    CREATE TABLE IF NOT EXISTS discovered_work (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      station TEXT NOT NULL,
      title TEXT NOT NULL,
      classification TEXT NOT NULL,
      status TEXT NOT NULL,
      evidence_json TEXT NOT NULL,
      external_reference TEXT,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS instruction_pack_uses (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      station TEXT NOT NULL,
      name TEXT NOT NULL,
      version INTEGER NOT NULL,
      source TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      status TEXT NOT NULL,
      recorded_at TEXT NOT NULL,
      UNIQUE(run_id, station, name, version)
    );
    CREATE TABLE IF NOT EXISTS factory_queue (
      id TEXT PRIMARY KEY,
      workflow_name TEXT NOT NULL,
      work_ref TEXT NOT NULL,
      options_json TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL,
      submitted_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      run_id TEXT,
      error_json TEXT
    );
    CREATE TABLE IF NOT EXISTS factory_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      factory_id TEXT NOT NULL,
      event TEXT NOT NULL,
      prior_state TEXT,
      result_state TEXT NOT NULL,
      actor TEXT NOT NULL,
      reason TEXT,
      occurred_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS delivery_requests (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      adapter TEXT NOT NULL,
      artifact TEXT NOT NULL,
      target_environment TEXT NOT NULL,
      authority TEXT NOT NULL,
      checks_json TEXT NOT NULL,
      recovery_method TEXT NOT NULL,
      secret_env_json TEXT NOT NULL,
      request_json TEXT NOT NULL,
      status TEXT NOT NULL,
      effect_id TEXT,
      result_json TEXT,
      requested_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT
    );
    CREATE TABLE IF NOT EXISTS standard_work_proposals (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      version INTEGER NOT NULL,
      proposal TEXT NOT NULL,
      expected_result TEXT NOT NULL,
      status TEXT NOT NULL,
      approval_decision_id TEXT,
      evaluation_json TEXT,
      created_at TEXT NOT NULL,
      UNIQUE(run_id, version)
    );
    CREATE TABLE IF NOT EXISTS cleanup_events (
      id TEXT PRIMARY KEY,
      artifact_id TEXT,
      run_id TEXT,
      relative_path TEXT NOT NULL,
      content_hash TEXT,
      byte_size INTEGER,
      reason TEXT NOT NULL,
      actor TEXT NOT NULL,
      removed_at TEXT NOT NULL
    );
    PRAGMA user_version = 1;
    COMMIT;
    """
  end

  defp migration_v2 do
    """
    BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS factory_queue (
      id TEXT PRIMARY KEY,
      workflow_name TEXT NOT NULL,
      work_ref TEXT NOT NULL,
      options_json TEXT NOT NULL DEFAULT '{}',
      status TEXT NOT NULL,
      submitted_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      run_id TEXT,
      error_json TEXT
    );
    CREATE TABLE IF NOT EXISTS factory_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      factory_id TEXT NOT NULL,
      event TEXT NOT NULL,
      prior_state TEXT,
      result_state TEXT NOT NULL,
      actor TEXT NOT NULL,
      reason TEXT,
      occurred_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS instruction_pack_uses (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      station TEXT NOT NULL,
      name TEXT NOT NULL,
      version INTEGER NOT NULL,
      source TEXT NOT NULL,
      content_hash TEXT NOT NULL,
      status TEXT NOT NULL,
      recorded_at TEXT NOT NULL,
      UNIQUE(run_id, station, name, version)
    );
    PRAGMA user_version = 2;
    COMMIT;
    """
  end

  defp migration_v3 do
    """
    BEGIN IMMEDIATE;
    CREATE TABLE IF NOT EXISTS delivery_requests (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      adapter TEXT NOT NULL,
      artifact TEXT NOT NULL,
      target_environment TEXT NOT NULL,
      authority TEXT NOT NULL,
      checks_json TEXT NOT NULL,
      recovery_method TEXT NOT NULL,
      secret_env_json TEXT NOT NULL,
      request_json TEXT NOT NULL,
      status TEXT NOT NULL,
      effect_id TEXT,
      result_json TEXT,
      requested_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT
    );
    CREATE TABLE IF NOT EXISTS standard_work_proposals (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL,
      version INTEGER NOT NULL,
      proposal TEXT NOT NULL,
      expected_result TEXT NOT NULL,
      status TEXT NOT NULL,
      approval_decision_id TEXT,
      evaluation_json TEXT,
      created_at TEXT NOT NULL,
      UNIQUE(run_id, version)
    );
    CREATE TABLE IF NOT EXISTS cleanup_events (
      id TEXT PRIMARY KEY,
      artifact_id TEXT,
      run_id TEXT,
      relative_path TEXT NOT NULL,
      content_hash TEXT,
      byte_size INTEGER,
      reason TEXT NOT NULL,
      actor TEXT NOT NULL,
      removed_at TEXT NOT NULL
    );
    SELECT id, run_id, version FROM standard_work_proposals LIMIT 0;
    PRAGMA user_version = 3;
    COMMIT;
    """
  end
end
