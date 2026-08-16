defmodule Hancho.Factory.Store do
  @moduledoc false

  alias Hancho.{Clock, ID, JSON, SQLite, Store}

  def submit(repository, workflow, work_ref, options \\ %{}) do
    id = ID.generate("queue")
    now = Clock.utc_now()

    sql = """
    INSERT INTO factory_queue (id, workflow_name, work_ref, options_json, status, submitted_at)
    VALUES (#{q(id)}, #{q(workflow)}, #{q(work_ref)}, #{q(JSON.encode!(options))}, 'ready', #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql), do: get(repository, id)
  end

  def get(repository, id) do
    with {:ok, [item]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM factory_queue WHERE id = #{q(id)} LIMIT 1;"
           ) do
      {:ok, item}
    else
      {:ok, []} -> {:error, :not_found}
      error -> error
    end
  end

  def ready(repository, limit) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM factory_queue WHERE status = 'ready' ORDER BY submitted_at, id LIMIT #{q(limit)};"
    )
  end

  def list(repository) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM factory_queue ORDER BY submitted_at, id;"
    )
  end

  def claim(repository, id) do
    claim(repository, id, nil)
  end

  def claim(repository, id, factory_id) do
    now = Clock.utc_now()

    release_event =
      if is_binary(factory_id) do
        """
        INSERT INTO factory_events
          (factory_id, event, prior_state, result_state, actor, reason, occurred_at)
        SELECT #{q(factory_id)}, 'work_released', 'ready', 'active', 'hancho',
               #{q("Queue item #{id} entered WIP after durable release.")}, #{q(now)}
        WHERE changes() = 1;
        """
      else
        ""
      end

    sql = """
    BEGIN IMMEDIATE;
    UPDATE factory_queue SET status = 'active', started_at = #{q(now)}
      WHERE id = #{q(id)} AND status = 'ready';
    #{release_event}
    COMMIT;
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, item} <- get(repository, id) do
      if item["status"] == "active", do: {:ok, item}, else: {:error, :claim_conflict}
    end
  end

  def finish(repository, id, status, run_id, error \\ nil)
      when status in ["complete", "stopped", "failed", "cancelled"] do
    now = Clock.utc_now()

    SQLite.execute(
      Store.path(repository),
      "UPDATE factory_queue SET status = #{q(status)}, finished_at = #{q(now)}, run_id = #{q(run_id)}, error_json = #{q(encode_error(error))} WHERE id = #{q(id)} AND status = 'active';"
    )
  end

  def recover_active(repository) do
    SQLite.execute(
      Store.path(repository),
      "UPDATE factory_queue SET status = 'failed', finished_at = #{q(Clock.utc_now())}, error_json = #{q(JSON.encode!(%{code: "controller_interrupted", message: "The controller stopped while this queue item was active."}))} WHERE status = 'active';"
    )
  end

  def event(repository, factory_id, event, prior_state, result_state, actor, reason) do
    SQLite.execute(
      Store.path(repository),
      "INSERT INTO factory_events (factory_id, event, prior_state, result_state, actor, reason, occurred_at) VALUES (#{q(factory_id)}, #{q(event)}, #{q(prior_state)}, #{q(result_state)}, #{q(actor)}, #{q(reason)}, #{q(Clock.utc_now())});"
    )
  end

  def events(repository) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM factory_events ORDER BY id;"
    )
  end

  defp encode_error(nil), do: nil

  defp encode_error(%{__struct__: _} = error),
    do: JSON.encode!(%{message: Exception.message(error)})

  defp encode_error(error), do: JSON.encode!(error)
  defp q(value), do: SQLite.quote(value)
end
