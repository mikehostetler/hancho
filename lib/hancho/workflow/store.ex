defmodule Hancho.Workflow.Store do
  @moduledoc "Stores durable workflow state in the repository-local SQLite database."

  alias Exqlite.Result
  alias Hancho.Log.Event

  @schema [
    """
    CREATE TABLE IF NOT EXISTS workflow_runs (
      id TEXT PRIMARY KEY,
      workflow_name TEXT NOT NULL,
      workflow_version INTEGER NOT NULL,
      status TEXT NOT NULL,
      current_step TEXT,
      input_json TEXT NOT NULL,
      outputs_json TEXT NOT NULL,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      error_json TEXT
    )
    """,
    """
    CREATE TABLE IF NOT EXISTS workflow_steps (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      run_id TEXT NOT NULL,
      position INTEGER NOT NULL,
      name TEXT NOT NULL,
      action TEXT NOT NULL,
      status TEXT NOT NULL,
      params_json TEXT NOT NULL,
      result_json TEXT,
      started_at TEXT NOT NULL,
      finished_at TEXT,
      error_json TEXT,
      UNIQUE(run_id, position),
      FOREIGN KEY(run_id) REFERENCES workflow_runs(id)
    )
    """,
    "CREATE INDEX IF NOT EXISTS workflow_steps_run_id ON workflow_steps(run_id)"
  ]

  @spec open(String.t()) :: {:ok, pid()} | {:error, term()}
  def open(path) do
    with :ok <- Hancho.Native.ensure_exqlite(Path.dirname(path)),
         {:ok, _applications} <- Application.ensure_all_started(:exqlite),
         :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, connection} <- Exqlite.start_link(database: path),
         :ok <- migrate(connection) do
      {:ok, connection}
    end
  end

  @spec close(pid()) :: :ok
  def close(connection) when is_pid(connection) do
    if Process.alive?(connection), do: GenServer.stop(connection, :normal, :infinity)
    :ok
  end

  @spec create_run(pid(), String.t(), Hancho.Workflow.Definition.t(), map()) ::
          :ok | {:error, term()}
  def create_run(connection, id, definition, input) do
    execute(
      connection,
      """
      INSERT INTO workflow_runs
        (id, workflow_name, workflow_version, status, input_json, outputs_json, started_at)
      VALUES (?, ?, ?, 'running', ?, '{}', ?)
      """,
      [id, definition.name, definition.version, encode(input), now()]
    )
  end

  @spec start_step(pid(), String.t(), non_neg_integer(), Hancho.Workflow.Step.t(), map()) ::
          :ok | {:error, term()}
  def start_step(connection, run_id, position, step, params) do
    with :ok <-
           execute(
             connection,
             """
             INSERT INTO workflow_steps
               (run_id, position, name, action, status, params_json, started_at)
             VALUES (?, ?, ?, ?, 'running', ?, ?)
             """,
             [run_id, position, step.name, step.action, encode(params), now()]
           ) do
      execute(
        connection,
        "UPDATE workflow_runs SET current_step = ? WHERE id = ?",
        [step.name, run_id]
      )
    end
  end

  @spec complete_step(pid(), String.t(), non_neg_integer(), map(), map()) ::
          :ok | {:error, term()}
  def complete_step(connection, run_id, position, result, outputs) do
    with :ok <-
           execute(
             connection,
             """
             UPDATE workflow_steps
             SET status = 'completed', result_json = ?, finished_at = ?
             WHERE run_id = ? AND position = ?
             """,
             [encode(result), now(), run_id, position]
           ) do
      execute(
        connection,
        "UPDATE workflow_runs SET outputs_json = ? WHERE id = ?",
        [encode(outputs), run_id]
      )
    end
  end

  @spec complete_run(pid(), String.t(), map()) :: :ok | {:error, term()}
  def complete_run(connection, run_id, outputs) do
    execute(
      connection,
      """
      UPDATE workflow_runs
      SET status = 'completed', current_step = NULL, outputs_json = ?, finished_at = ?
      WHERE id = ?
      """,
      [encode(outputs), now(), run_id]
    )
  end

  @spec fail_step(pid(), String.t(), non_neg_integer(), term()) :: :ok | {:error, term()}
  def fail_step(connection, run_id, position, error) do
    execute(
      connection,
      """
      UPDATE workflow_steps
      SET status = 'stopped', error_json = ?, finished_at = ?
      WHERE run_id = ? AND position = ?
      """,
      [encode(error), now(), run_id, position]
    )
  end

  @spec fail_run(pid(), String.t(), String.t(), map(), term()) :: :ok | {:error, term()}
  def fail_run(connection, run_id, step_name, outputs, error) do
    execute(
      connection,
      """
      UPDATE workflow_runs
      SET status = 'stopped', current_step = ?, outputs_json = ?, error_json = ?, finished_at = ?
      WHERE id = ?
      """,
      [step_name, encode(outputs), encode(error), now(), run_id]
    )
  end

  @spec fetch_run(pid(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_run(connection, id) do
    query_one(
      connection,
      """
      SELECT id, workflow_name, workflow_version, status, current_step,
             input_json, outputs_json, started_at, finished_at, error_json
      FROM workflow_runs WHERE id = ?
      """,
      [id]
    )
  end

  @spec list_steps(pid(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_steps(connection, run_id) do
    case Exqlite.query(
           connection,
           """
           SELECT position, name, action, status, params_json, result_json,
                  started_at, finished_at, error_json
           FROM workflow_steps WHERE run_id = ? ORDER BY position
           """,
           [run_id]
         ) do
      {:ok, %Result{columns: columns, rows: rows}} ->
        {:ok, Enum.map(rows, &row_map(columns, &1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp migrate(connection) do
    with :ok <- execute(connection, "PRAGMA journal_mode = WAL"),
         :ok <- execute(connection, "PRAGMA foreign_keys = ON") do
      Enum.reduce_while(@schema, :ok, fn statement, :ok ->
        case execute(connection, statement) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp execute(connection, statement, params \\ []) do
    case Exqlite.query(connection, statement, params) do
      {:ok, %Result{}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp query_one(connection, statement, params) do
    case Exqlite.query(connection, statement, params) do
      {:ok, %Result{columns: columns, rows: [row]}} -> {:ok, row_map(columns, row)}
      {:ok, %Result{rows: []}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp row_map(columns, row), do: columns |> Enum.zip(row) |> Map.new()
  defp encode(value), do: value |> Event.normalize() |> Jason.encode!()
  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
