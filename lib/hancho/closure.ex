defmodule Hancho.Closure do
  @moduledoc "Records receiver acceptance, closes execution before commitment, and proposes useful learning."

  alias Hancho.WorkSource.{Beadwork, GitHub}

  alias Hancho.{
    Artifacts,
    Clock,
    Delivery,
    Error,
    ID,
    Journal,
    JSON,
    Repository,
    SQLite,
    Store,
    WorkRecords
  }

  @spec close(Repository.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def close(repository, run_id, receiver_result, options \\ []) do
    with true <- is_binary(receiver_result) and receiver_result != "",
         {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         {:ok, merge} <- confirmed_merge(repository, run_id),
         {:ok, delivery} <-
           required_delivery(repository, run_id, Keyword.get(options, :delivery_required, false)),
         {:ok, references} <- WorkRecords.list(repository, run_id),
         {:ok, receiver} <- write_receiver(repository, run_id, receiver_result, merge, delivery),
         {:ok, beadwork} <- close_beadwork(repository, run_id, references, receiver_result),
         {:ok, github} <-
           close_github(
             repository,
             run_id,
             references,
             work_order,
             receiver_result,
             receiver,
             merge,
             delivery
           ),
         {:ok, proposal} <-
           maybe_propose_learning(
             repository,
             run_id,
             Keyword.get(options, :learning),
             Keyword.get(options, :expected_result)
           ),
         {:ok, _event} <-
           Journal.record_event(repository, run_id, "work_closed",
             actor: "receiver",
             reason: receiver_result,
             payload: %{
               receiver_artifact: receiver["content_hash"],
               beadwork: effect_id(beadwork),
               github: effect_id(github),
               standard_work_proposal: proposal && proposal["id"]
             }
           ) do
      {:ok,
       %{
         work_order: work_order,
         receiver: receiver,
         beadwork: beadwork,
         github: github,
         proposal: proposal
       }}
    else
      false ->
        {:error,
         error(:receiver_result_required, "A receiver result is required before closure.")}

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp confirmed_merge(repository, run_id) do
    with {:ok, rows} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM effects WHERE run_id = #{q(run_id)} AND kind = 'github_merge' AND status = 'confirmed' ORDER BY observed_at DESC LIMIT 1;"
           ) do
      case rows do
        [effect] ->
          {:ok, effect}

        [] ->
          {:error,
           error(
             :merge_required_for_closure,
             "A confirmed merge is required before work closure."
           )}
      end
    end
  end

  defp required_delivery(_repository, _run_id, false), do: {:ok, nil}

  defp required_delivery(repository, run_id, true) do
    with {:ok, deliveries} <- Delivery.list(repository, run_id) do
      case Enum.find(Enum.reverse(deliveries), &(&1["status"] == "confirmed")) do
        nil ->
          {:error,
           error(
             :delivery_required_for_closure,
             "A confirmed delivery is required before closure."
           )}

        delivery ->
          {:ok, delivery}
      end
    end
  end

  defp write_receiver(repository, run_id, receiver_result, merge, delivery) do
    Artifacts.write(
      repository,
      run_id,
      "receipt",
      "receiver.json",
      JSON.encode!(%{
        schema_version: 1,
        receiver_result: receiver_result,
        accepted_at: Clock.utc_now(),
        merge_effect_id: merge["id"],
        delivery_request_id: delivery && delivery["id"]
      }),
      media_type: "application/json",
      retention: "durable"
    )
  end

  defp close_beadwork(repository, run_id, references, receiver_result) do
    case Enum.find(references, &(&1["kind"] == "beadwork")) do
      nil ->
        {:ok, nil}

      reference ->
        require_confirmed(
          Beadwork.close(
            repository,
            run_id,
            reference["reference"],
            "Execution ended after merge or delivery. Receiver result: #{receiver_result}"
          ),
          "Beadwork closure"
        )
    end
  end

  defp close_github(
         repository,
         run_id,
         references,
         work_order,
         receiver_result,
         receiver,
         merge,
         delivery
       ) do
    case Enum.find(references, &(&1["kind"] == "github_issue")) do
      nil ->
        {:ok, nil}

      reference ->
        final_note = """
        Hancho result: #{receiver_result}

        Work order: #{work_order["id"]}
        Merge effect: #{merge["id"]}
        Delivery: #{if delivery, do: delivery["id"], else: "not required"}
        Receiver evidence: #{receiver["relative_path"]} (sha256 #{receiver["content_hash"]})
        """

        require_confirmed(
          GitHub.close_issue(repository, run_id, reference["reference"], final_note),
          "GitHub Issue closure"
        )
    end
  end

  defp require_confirmed({:ok, %{"status" => "confirmed"} = effect}, _name), do: {:ok, effect}

  defp require_confirmed({:ok, effect}, name),
    do:
      {:error,
       error(
         :closure_effect_uncertain,
         "#{name} is '#{effect["status"]}' and needs reconciliation."
       )}

  defp require_confirmed({:error, failure}, _name), do: {:error, failure}

  defp maybe_propose_learning(_repository, _run_id, nil, _expected_result), do: {:ok, nil}
  defp maybe_propose_learning(_repository, _run_id, "", _expected_result), do: {:ok, nil}

  defp maybe_propose_learning(repository, run_id, learning, expected_result) do
    expected_result =
      expected_result || "Reduce repeated delay or defects without unacceptable harm."

    with {:ok, version} <- next_proposal_version(repository, run_id),
         id <- ID.generate("kaizen"),
         :ok <-
           SQLite.execute(
             Store.path(repository),
             "INSERT INTO standard_work_proposals (id, run_id, version, proposal, expected_result, status, created_at) VALUES (#{q(id)}, #{q(run_id)}, #{q(version)}, #{q(learning)}, #{q(expected_result)}, 'proposed', #{q(Clock.utc_now())});"
           ),
         {:ok, decision} <-
           Journal.request_decision(repository, run_id, "standard_work_change", %{
             proposal_id: id,
             version: version,
             proposal: learning,
             expected_result: expected_result
           }),
         :ok <-
           SQLite.execute(
             Store.path(repository),
             "UPDATE standard_work_proposals SET approval_decision_id = #{q(decision["id"])} WHERE id = #{q(id)};"
           ),
         {:ok, [proposal]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM standard_work_proposals WHERE id = #{q(id)};"
           ) do
      {:ok, proposal}
    end
  end

  defp next_proposal_version(repository, run_id) do
    with {:ok, value} <-
           SQLite.scalar(
             Store.path(repository),
             "SELECT COALESCE(MAX(version), 0) + 1 FROM standard_work_proposals WHERE run_id = #{q(run_id)};"
           ),
         do: {:ok, value || 1}
  end

  defp effect_id(nil), do: nil
  defp effect_id(effect), do: effect["id"]
  defp q(value), do: SQLite.quote(value)
  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
