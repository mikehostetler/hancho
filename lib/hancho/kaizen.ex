defmodule Hancho.Kaizen do
  @moduledoc "Approves and evaluates versioned standard-work proposals without rewriting history."

  alias Hancho.{Clock, Error, JSON, Repository, SQLite, Store}

  @spec list(Repository.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(repository) do
    with :ok <- refresh(repository) do
      SQLite.query(
        Store.path(repository),
        "SELECT * FROM standard_work_proposals ORDER BY created_at, id;"
      )
    end
  end

  @spec evaluate(Repository.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(repository, proposal_id, actual_result)
      when is_binary(actual_result) and actual_result != "" do
    with :ok <- refresh(repository),
         {:ok, [proposal]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM standard_work_proposals WHERE id = #{q(proposal_id)} LIMIT 1;"
           ),
         true <- proposal["status"] == "approved",
         evaluation <- %{actual_result: actual_result, evaluated_at: Clock.utc_now()},
         :ok <-
           SQLite.execute(
             Store.path(repository),
             "UPDATE standard_work_proposals SET status = 'evaluated', evaluation_json = #{q(JSON.encode!(evaluation))} WHERE id = #{q(proposal_id)} AND status = 'approved';"
           ),
         {:ok, [updated]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM standard_work_proposals WHERE id = #{q(proposal_id)};"
           ) do
      {:ok, updated}
    else
      false ->
        {:error,
         error(:kaizen_not_approved, "Standard-work proposal must be approved before evaluation.")}

      {:ok, []} ->
        {:error,
         error(:kaizen_not_found, "Standard-work proposal '#{proposal_id}' was not found.")}

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp refresh(repository) do
    SQLite.execute(Store.path(repository), """
    UPDATE standard_work_proposals
    SET status = (
      SELECT CASE decisions.status
        WHEN 'approved' THEN 'approved'
        WHEN 'rejected' THEN 'rejected'
        ELSE standard_work_proposals.status
      END
      FROM decisions WHERE decisions.id = standard_work_proposals.approval_decision_id
    )
    WHERE status = 'proposed' AND approval_decision_id IS NOT NULL;
    """)
  end

  defp q(value), do: SQLite.quote(value)
  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
