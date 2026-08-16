defmodule Hancho.ReadModel do
  @moduledoc false

  alias Hancho.{Artifacts, Error, Journal, Repository, SQLite, Store}

  @spec show(Repository.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def show(repository, run_id) do
    with {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         {:ok, events} <- Journal.events(repository, run_id),
         {:ok, artifacts} <- Artifacts.list(repository, run_id),
         {:ok, actions} <- by_run(repository, "actions", run_id, "requested_at"),
         {:ok, effects} <- by_run(repository, "effects", run_id, "intent_at"),
         {:ok, decisions} <- by_run(repository, "decisions", run_id, "requested_at"),
         {:ok, sessions} <- by_run(repository, "harness_sessions", run_id, "started_at") do
      {:ok,
       %{
         work_order: work_order,
         events: events,
         artifacts: artifacts,
         actions: actions,
         effects: effects,
         decisions: decisions,
         harness_sessions: sessions,
         next_action: next_action(work_order, decisions, effects)
       }}
    end
  end

  @spec normalized_logs(Repository.t(), String.t() | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def normalized_logs(repository, run_id \\ nil) do
    if run_id do
      SQLite.query(
        Store.path(repository),
        "SELECT * FROM events WHERE run_id = #{SQLite.quote(run_id)} ORDER BY occurred_at, run_id, seq;"
      )
    else
      SQLite.query(
        Store.path(repository),
        """
        SELECT run_id, seq, actor, occurred_at, prior_state, event, result_state, reason,
               correlation_id, payload_json
        FROM events
        UNION ALL
        SELECT factory_id AS run_id, id AS seq, actor, occurred_at, prior_state, event,
               result_state, reason, factory_id AS correlation_id,
               '{"observation":true,"payload":{"station":"factory"}}' AS payload_json
        FROM factory_events
        ORDER BY occurred_at, run_id, seq;
        """
      )
    end
  end

  @spec filtered_logs(Repository.t(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def filtered_logs(repository, options) do
    with {:ok, events} <- normalized_logs(repository, Keyword.get(options, :run_id)) do
      events =
        events
        |> filter_since(Keyword.get(options, :since))
        |> filter_station(Keyword.get(options, :station))

      {:ok, events}
    end
  end

  @spec raw_logs(Repository.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def raw_logs(repository, run_id) do
    with {:ok, rows} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM artifacts WHERE run_id = #{SQLite.quote(run_id)} AND kind = 'log' ORDER BY created_at, id;"
           ) do
      {:ok,
       Enum.map(rows, fn row ->
         path = Path.join(repository.runtime_dir, row["relative_path"])
         Map.put(row, "content", if(File.exists?(path), do: File.read!(path), else: nil))
       end)}
    end
  end

  @spec andon_stops(Repository.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def andon_stops(repository) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM events WHERE event = 'andon' ORDER BY occurred_at, run_id, seq;"
    )
  end

  defp by_run(repository, table, run_id, order) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM #{table} WHERE run_id = #{SQLite.quote(run_id)} ORDER BY #{order}, id;"
    )
  end

  defp next_action(work_order, decisions, effects) do
    cond do
      Enum.any?(effects, &(&1["status"] == "uncertain")) ->
        "hancho reconcile #{work_order["id"]}"

      decision = Enum.find(decisions, &(&1["status"] == "pending")) ->
        "hancho approve #{decision["id"]} --reason TEXT"

      work_order["status"] in ["stopped", "cancelled"] ->
        "hancho show #{work_order["id"]}"

      work_order["status"] == "complete" ->
        nil

      true ->
        "hancho resume #{work_order["id"]}"
    end
  end

  defp filter_since(events, nil), do: events

  defp filter_since(events, since) do
    case since_time(since) do
      {:ok, cutoff} -> Enum.filter(events, &(&1["occurred_at"] >= cutoff))
      :error -> events
    end
  end

  defp filter_station(events, nil), do: events

  defp filter_station(events, station) do
    Enum.filter(events, fn event ->
      payload = Hancho.JSON.decode!(event["payload_json"] || "{}")

      station == get_in(payload, ["payload", "station"]) or
        Enum.any?(payload["actions"] || [], fn action ->
          (action["station"] || action[:station]) == station
        end) or event["result_state"] == station
    end)
  end

  defp since_time(value) do
    case Regex.run(~r/^(\d+)([smhd])$/, value) do
      [_, amount, unit] ->
        multiplier = Map.fetch!(%{"s" => 1, "m" => 60, "h" => 3_600, "d" => 86_400}, unit)

        {:ok,
         DateTime.utc_now()
         |> DateTime.add(-String.to_integer(amount) * multiplier, :second)
         |> DateTime.to_iso8601()}

      _ ->
        case DateTime.from_iso8601(value) do
          {:ok, time, _offset} -> {:ok, DateTime.to_iso8601(time)}
          _ -> :error
        end
    end
  end
end
