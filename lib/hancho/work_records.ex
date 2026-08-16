defmodule Hancho.WorkRecords do
  @moduledoc "Stores the separate GitHub commitment and Beadwork execution references."

  alias Hancho.{Clock, Error, ID, JSON, Repository, SQLite, Store}

  @spec link(Repository.t(), String.t(), keyword()) :: :ok | {:error, Error.t()}
  def link(repository, run_id, options) do
    references =
      [
        {"github_issue", Keyword.get(options, :github_issue)},
        {"beadwork", Keyword.get(options, :beadwork)}
      ]
      |> Enum.reject(fn {_kind, reference} -> is_nil(reference) end)

    if references == [] do
      {:error,
       %Error{
         code: :work_reference_required,
         exit_status: 65,
         message: "A work order needs a GitHub Issue or Beadwork reference."
       }}
    else
      now = Clock.utc_now()

      sql =
        references
        |> Enum.map_join("\n", fn {kind, reference} ->
          "INSERT INTO work_references (id, run_id, kind, reference, canonical, metadata_json, created_at) VALUES (#{q(ID.generate("ref"))}, #{q(run_id)}, #{q(kind)}, #{q(reference)}, 1, #{q(JSON.encode!(Keyword.get(options, :metadata, %{})))}, #{q(now)});"
        end)

      SQLite.execute(Store.path(repository), "BEGIN IMMEDIATE;\n#{sql}\nCOMMIT;")
    end
  end

  @spec list(Repository.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(repository, run_id) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM work_references WHERE run_id = #{q(run_id)} ORDER BY kind, id;"
    )
  end

  @spec classify_discovery(map()) :: String.t()
  def classify_discovery(discovery) do
    if Enum.any?(~w(scope_change cross_repository customer_commit material_risk), fn key ->
         discovery[key] == true or discovery[String.to_atom(key)] == true
       end) do
      "decision_required"
    else
      "small_internal"
    end
  end

  @spec record_discovery(Repository.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def record_discovery(repository, run_id, station, discovery) do
    id = ID.generate("discovery")
    classification = classify_discovery(discovery)
    status = if classification == "decision_required", do: "pending_decision", else: "recorded"
    now = Clock.utc_now()

    sql = """
    INSERT INTO discovered_work
      (id, run_id, station, title, classification, status, evidence_json, created_at)
    VALUES
      (#{q(id)}, #{q(run_id)}, #{q(station)}, #{q(discovery["title"] || discovery[:title])},
       #{q(classification)}, #{q(status)}, #{q(JSON.encode!(discovery["evidence"] || discovery[:evidence] || %{}))}, #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, [row]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM discovered_work WHERE id = #{q(id)};"
           ),
         {:ok, decision} <- maybe_request_discovery_decision(repository, row, discovery) do
      {:ok, if(decision, do: Map.put(row, "decision_id", decision["id"]), else: row)}
    end
  end

  defp maybe_request_discovery_decision(
         repository,
         %{"classification" => "decision_required"} = row,
         discovery
       ) do
    Hancho.Journal.request_decision(repository, row["run_id"], "discovered_scope", %{
      discovery_id: row["id"],
      title: row["title"],
      classification: row["classification"],
      evidence: discovery["evidence"] || discovery[:evidence] || %{}
    })
  end

  defp maybe_request_discovery_decision(_repository, _row, _discovery), do: {:ok, nil}

  defp q(value), do: SQLite.quote(value)
end
