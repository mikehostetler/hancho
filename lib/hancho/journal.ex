defmodule Hancho.Journal do
  @moduledoc "Durable work-order, event, action, effect, and decision operations."

  alias Hancho.Workflow.{Definition, Engine, Event}
  alias Hancho.{Clock, Error, ID, JSON, Repository, SQLite, Store}

  @spec create_work_order(Repository.t(), map(), Definition.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_work_order(repository, config, definition, work_ref, attributes \\ %{}) do
    run_id = Map.get(attributes, :id, ID.generate("run"))
    now = Clock.utc_now()
    repository_id = repository.id || read_repository_id(repository)

    if is_nil(repository_id) do
      {:error,
       %Error{
         code: :repository_not_initialized,
         exit_status: 66,
         message: "Repository has no Hancho identity. Run 'hancho init'."
       }}
    else
      sql = """
      BEGIN IMMEDIATE;
      INSERT OR IGNORE INTO repositories (id, root, git_common_dir, remote, created_at)
      VALUES (#{q(repository_id)}, #{q(repository.root)}, #{q(repository.git_common_dir)}, #{q(repository.remote)}, #{q(now)});
      INSERT INTO work_orders
        (id, repository_id, workflow_name, workflow_version, work_ref, state, status, config_hash,
         baseline_commit, target_branch, created_at, updated_at)
      VALUES
        (#{q(run_id)}, #{q(repository_id)}, #{q(definition.name)}, #{q(definition.version)}, #{q(work_ref)},
         #{q(definition.initial_state)}, 'ready', #{q(config.hash)}, #{q(Map.get(attributes, :baseline_commit))},
         #{q(Map.get(attributes, :target_branch))}, #{q(now)}, #{q(now)});
      INSERT INTO events
        (run_id, seq, actor, occurred_at, prior_state, event, result_state, reason, correlation_id, payload_json)
      VALUES
        (#{q(run_id)}, 1, #{q(Map.get(attributes, :actor, "hancho"))}, #{q(now)}, NULL, 'created',
         #{q(definition.initial_state)}, #{q(Map.get(attributes, :reason, "Work order created"))},
         #{q(ID.generate("evt"))}, #{q(JSON.encode!(%{workflow: definition.name, version: definition.version, work_ref: work_ref}))});
      COMMIT;
      """

      with :ok <- SQLite.execute(Store.path(repository), sql),
           {:ok, work_order} <- get_work_order(repository, run_id) do
        {:ok, work_order}
      end
    end
  end

  @spec transition(Repository.t(), String.t(), Definition.t(), Event.t() | String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def transition(repository, run_id, definition, event, facts \\ %{}) do
    event = normalize_event(event)

    with {:ok, work_order} <- get_work_order(repository, run_id),
         :ok <- validate_pin(work_order, definition),
         {:ok, result} <- Engine.transition(definition, work_order["state"], event, facts),
         :ok <- persist_transition(repository, work_order, event, result, facts),
         {:ok, updated} <- get_work_order(repository, run_id) do
      if updated["state"] == result.state do
        {:ok, Map.put(result, :work_order, updated)}
      else
        {:error,
         %Error{
           code: :transition_conflict,
           exit_status: 75,
           message: "Work order '#{run_id}' changed before event '#{event.name}' could be stored."
         }}
      end
    end
  end

  @spec get_work_order(Repository.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def get_work_order(repository, run_id) do
    with {:ok, rows} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM work_orders WHERE id = #{q(run_id)} LIMIT 1;"
           ) do
      case rows do
        [row] ->
          {:ok, row}

        [] ->
          {:error,
           %Error{
             code: :run_not_found,
             exit_status: 66,
             message: "Work order '#{run_id}' was not found."
           }}
      end
    end
  end

  @spec list_work_orders(Repository.t(), non_neg_integer()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def list_work_orders(repository, limit \\ 50) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM work_orders ORDER BY created_at DESC, id DESC LIMIT #{q(limit)};"
    )
  end

  @spec events(Repository.t(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def events(repository, run_id) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM events WHERE run_id = #{q(run_id)} ORDER BY seq ASC;"
    )
  end

  @spec record_event(Repository.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def record_event(repository, run_id, event_name, options \\ []) do
    with {:ok, work_order} <- get_work_order(repository, run_id) do
      now = Clock.utc_now()
      payload = JSON.encode!(%{observation: true, payload: Keyword.get(options, :payload, %{})})

      sql = """
      BEGIN IMMEDIATE;
      INSERT INTO events
        (run_id, seq, actor, occurred_at, prior_state, event, result_state, reason, correlation_id, payload_json)
      VALUES
        (#{q(run_id)}, COALESCE((SELECT MAX(seq) + 1 FROM events WHERE run_id = #{q(run_id)}), 1),
         #{q(Keyword.get(options, :actor, "hancho"))}, #{q(now)}, #{q(work_order["state"])},
         #{q(event_name)}, #{q(work_order["state"])}, #{q(Keyword.get(options, :reason))},
         #{q(ID.generate("evt"))}, #{q(payload)});
      UPDATE work_orders SET updated_at = #{q(now)} WHERE id = #{q(run_id)};
      COMMIT;
      """

      with :ok <- SQLite.execute(Store.path(repository), sql) do
        {:ok, %{event: event_name, state: work_order["state"], work_order: work_order}}
      end
    end
  end

  @spec verify_replay(Repository.t(), String.t(), Definition.t()) :: :ok | {:error, Error.t()}
  def verify_replay(repository, run_id, definition) do
    with {:ok, work_order} <- get_work_order(repository, run_id),
         {:ok, events} <- events(repository, run_id) do
      replay_result =
        events
        |> Enum.reject(fn row ->
          row["event"] == "created" or
            JSON.decode!(row["payload_json"] || "{}")["observation"] == true
        end)
        |> Enum.reduce_while({:ok, definition.initial_state}, fn row, {:ok, state} ->
          payload = JSON.decode!(row["payload_json"] || "{}")
          facts = atomize_fact_keys(payload["facts"] || %{})

          case Engine.transition(definition, state, row["event"], facts) do
            {:ok, transition} -> {:cont, {:ok, transition.state}}
            {:error, rejection} -> {:halt, {:error, rejection}}
          end
        end)

      stored_state = work_order["state"]

      case replay_result do
        {:ok, ^stored_state} ->
          :ok

        {:ok, state} ->
          replay_error(run_id, "replay ended at '#{state}', stored state is '#{stored_state}'")

        {:error, rejection} ->
          replay_error(run_id, rejection.message)
      end
    end
  end

  @spec request_action(Repository.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_action(repository, run_id, station, kind, idempotency_key) do
    id = ID.generate("action")
    now = Clock.utc_now()

    sql = """
    INSERT OR IGNORE INTO actions
      (id, run_id, station, kind, status, idempotency_key, requested_at)
    VALUES (#{q(id)}, #{q(run_id)}, #{q(station)}, #{q(kind)}, 'requested', #{q(idempotency_key)}, #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, [action]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM actions WHERE idempotency_key = #{q(idempotency_key)} LIMIT 1;"
           ) do
      {:ok, action}
    end
  end

  @spec start_action(Repository.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def start_action(repository, action_id) do
    change_action(repository, action_id, "requested", "started", nil)
  end

  @spec finish_action(Repository.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def finish_action(repository, action_id, status, result)
      when status in ["completed", "failed", "uncertain", "cancelled"] do
    change_action(repository, action_id, "started", status, result)
  end

  @spec effect_intent(Repository.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def effect_intent(repository, run_id, kind, target, idempotency_key) do
    id = ID.generate("effect")
    now = Clock.utc_now()

    sql = """
    INSERT OR IGNORE INTO effects
      (id, run_id, kind, target, status, idempotency_key, intent_at)
    VALUES (#{q(id)}, #{q(run_id)}, #{q(kind)}, #{q(target)}, 'intent', #{q(idempotency_key)}, #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, [effect]} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM effects WHERE idempotency_key = #{q(idempotency_key)} LIMIT 1;"
           ) do
      {:ok, effect}
    end
  end

  @spec observe_effect(Repository.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def observe_effect(repository, effect_id, status, observation)
      when status in ["confirmed", "absent", "failed", "uncertain", "contained", "reversed"] do
    now = Clock.utc_now()

    sql = """
    UPDATE effects SET status = #{q(status)}, observed_at = #{q(now)}, observation_json = #{q(JSON.encode!(observation))}
    WHERE id = #{q(effect_id)} AND status IN ('intent', 'uncertain');
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, effect} <- fetch_one(repository, "effects", effect_id) do
      if effect["status"] == status do
        {:ok, effect}
      else
        state_error(
          :effect_state_conflict,
          "Effect '#{effect_id}' cannot change from '#{effect["status"]}' to '#{status}'."
        )
      end
    end
  end

  @spec prepare_effect_retry(Repository.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def prepare_effect_retry(repository, %{"status" => "absent"} = effect) do
    with {:ok, work_order} <- get_work_order(repository, effect["run_id"]) do
      now = Clock.utc_now()

      payload =
        JSON.encode!(%{
          observation: true,
          payload: %{
            effect_id: effect["id"],
            prior_status: "absent",
            prior_observation: effect["observation_json"]
          }
        })

      sql = """
      BEGIN IMMEDIATE;
      UPDATE effects SET status = 'intent'
      WHERE id = #{q(effect["id"])} AND status = 'absent';
      INSERT INTO events
        (run_id, seq, actor, occurred_at, prior_state, event, result_state, reason, correlation_id, payload_json)
      SELECT
        #{q(effect["run_id"])},
        COALESCE((SELECT MAX(seq) + 1 FROM events WHERE run_id = #{q(effect["run_id"])}), 1),
        'hancho', #{q(now)}, #{q(work_order["state"])}, 'effect_retry_requested',
        #{q(work_order["state"])}, 'A confirmed absence permits an explicit retry',
        #{q(ID.generate("evt"))}, #{q(payload)}
      WHERE changes() = 1;
      UPDATE work_orders SET updated_at = #{q(now)} WHERE id = #{q(effect["run_id"])};
      COMMIT;
      """

      with :ok <- SQLite.execute(Store.path(repository), sql),
           {:ok, retried} <- fetch_one(repository, "effects", effect["id"]) do
        if retried["status"] == "intent" do
          {:ok, retried}
        else
          state_error(
            :effect_retry_conflict,
            "Effect '#{effect["id"]}' is '#{retried["status"]}' and cannot be retried."
          )
        end
      end
    end
  end

  def prepare_effect_retry(_repository, effect), do: {:ok, effect}

  @spec mark_incomplete_effects_uncertain(Repository.t()) :: :ok | {:error, Error.t()}
  def mark_incomplete_effects_uncertain(repository) do
    SQLite.execute(
      Store.path(repository),
      "UPDATE effects SET status = 'uncertain' WHERE status = 'intent';"
    )
  end

  @spec mark_incomplete_actions_uncertain(Repository.t()) :: :ok | {:error, Error.t()}
  def mark_incomplete_actions_uncertain(repository) do
    now = Clock.utc_now()
    result = JSON.encode!(%{reason: "Controller stopped before the action result was durable."})

    SQLite.execute(
      Store.path(repository),
      "UPDATE actions SET status = 'uncertain', finished_at = #{q(now)}, result_json = #{q(result)} WHERE status IN ('requested', 'started');"
    )
  end

  @spec uncertain_actions(Repository.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def uncertain_actions(repository) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM actions WHERE status = 'uncertain' ORDER BY requested_at, id;"
    )
  end

  @spec resolve_uncertain_actions(Repository.t(), String.t()) :: :ok | {:error, Error.t()}
  def resolve_uncertain_actions(repository, run_id) do
    result =
      JSON.encode!(%{observation: "No active harness process survived controller restart."})

    SQLite.execute(
      Store.path(repository),
      "UPDATE actions SET status = 'failed', result_json = #{q(result)} WHERE run_id = #{q(run_id)} AND status = 'uncertain';"
    )
  end

  @spec uncertain_effects(Repository.t(), String.t() | nil) ::
          {:ok, [map()]} | {:error, Error.t()}
  def uncertain_effects(repository, run_id \\ nil) do
    where =
      if run_id,
        do: "status = 'uncertain' AND run_id = #{q(run_id)}",
        else: "status = 'uncertain'"

    SQLite.query(
      Store.path(repository),
      "SELECT * FROM effects WHERE #{where} ORDER BY intent_at, id;"
    )
  end

  @spec request_decision(Repository.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_decision(repository, run_id, kind, request) do
    id = ID.generate("decision")
    now = Clock.utc_now()

    sql = """
    INSERT INTO decisions (id, run_id, kind, status, request_json, requested_at)
    VALUES (#{q(id)}, #{q(run_id)}, #{q(kind)}, 'pending', #{q(JSON.encode!(request))}, #{q(now)});
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         do: fetch_one(repository, "decisions", id)
  end

  @spec decide(Repository.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def decide(repository, decision_id, answer, actor, reason)
      when answer in ["approved", "rejected"] do
    now = Clock.utc_now()

    sql = """
    UPDATE decisions SET status = #{q(answer)}, actor = #{q(actor)}, reason = #{q(reason)}, decided_at = #{q(now)}
    WHERE id = #{q(decision_id)} AND status = 'pending';
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, decision} <- fetch_one(repository, "decisions", decision_id) do
      cond do
        decision["status"] == answer ->
          {:ok, decision}

        decision["status"] == "pending" ->
          state_error(:decision_not_recorded, "Decision '#{decision_id}' did not change.")

        true ->
          state_error(
            :decision_conflict,
            "Decision '#{decision_id}' is already '#{decision["status"]}'."
          )
      end
    end
  end

  @spec open_decisions(Repository.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def open_decisions(repository) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM decisions WHERE status = 'pending' ORDER BY requested_at, id;"
    )
  end

  @spec active_actions(Repository.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def active_actions(repository) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM actions WHERE status IN ('requested', 'started') ORDER BY requested_at, id;"
    )
  end

  defp persist_transition(repository, work_order, event, result, facts) do
    now = Clock.utc_now()
    status = status_for(result.state, result.terminal)
    payload = JSON.encode!(%{payload: event.payload, facts: facts, actions: result.actions})

    sql = """
    BEGIN IMMEDIATE;
    UPDATE work_orders
      SET state = #{q(result.state)}, status = #{q(status)}, updated_at = #{q(now)}
      WHERE id = #{q(work_order["id"])} AND state = #{q(work_order["state"])};
    INSERT INTO events
      (run_id, seq, actor, occurred_at, prior_state, event, result_state, reason, correlation_id, payload_json)
    SELECT
      #{q(work_order["id"])}, COALESCE((SELECT MAX(seq) + 1 FROM events WHERE run_id = #{q(work_order["id"])}), 1),
      #{q(event.actor || "hancho")}, #{q(now)}, #{q(work_order["state"])}, #{q(event.name)}, #{q(result.state)},
      #{q(event.reason)}, #{q(event.correlation_id || ID.generate("evt"))}, #{q(payload)}
    WHERE changes() = 1;
    COMMIT;
    """

    SQLite.execute(Store.path(repository), sql)
  end

  defp change_action(repository, action_id, prior_status, status, result) do
    now = Clock.utc_now()

    finished_at =
      if status in ["completed", "failed", "uncertain", "cancelled"], do: now, else: nil

    result_json = if result, do: JSON.encode!(result), else: nil

    sql = """
    UPDATE actions SET status = #{q(status)},
      started_at = CASE WHEN #{q(status)} = 'started' THEN #{q(now)} ELSE started_at END,
      finished_at = COALESCE(#{q(finished_at)}, finished_at),
      result_json = COALESCE(#{q(result_json)}, result_json)
    WHERE id = #{q(action_id)} AND status = #{q(prior_status)};
    """

    with :ok <- SQLite.execute(Store.path(repository), sql),
         {:ok, action} <- fetch_one(repository, "actions", action_id) do
      if action["status"] == status do
        {:ok, action}
      else
        state_error(
          :action_state_conflict,
          "Action '#{action_id}' cannot change from '#{action["status"]}' to '#{status}'."
        )
      end
    end
  end

  defp fetch_one(repository, table, id)
       when table in ["actions", "effects", "decisions", "artifacts", "harness_sessions"] do
    with {:ok, rows} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM #{table} WHERE id = #{q(id)} LIMIT 1;"
           ) do
      case rows do
        [row] ->
          {:ok, row}

        [] ->
          {:error,
           %Error{
             code: :record_not_found,
             exit_status: 66,
             message: "#{table} record '#{id}' was not found."
           }}
      end
    end
  end

  defp validate_pin(work_order, definition) do
    if work_order["workflow_name"] == definition.name and
         work_order["workflow_version"] == definition.version do
      :ok
    else
      {:error,
       %Error{
         code: :workflow_pin_mismatch,
         exit_status: 78,
         message:
           "Work order is pinned to #{work_order["workflow_name"]}.v#{work_order["workflow_version"]}."
       }}
    end
  end

  defp normalize_event(%Event{} = event), do: event
  defp normalize_event(name) when is_binary(name), do: %Event{name: name}

  defp status_for("stopped", _terminal), do: "stopped"
  defp status_for("cancelled", _terminal), do: "cancelled"
  defp status_for(_state, true), do: "complete"
  defp status_for(_state, false), do: "active"

  defp state_error(code, message),
    do: {:error, %Error{code: code, exit_status: 75, message: message}}

  defp replay_error(run_id, detail),
    do:
      {:error,
       %Error{
         code: :journal_replay_mismatch,
         exit_status: 74,
         message: "Work order '#{run_id}' journal mismatch: #{detail}."
       }}

  defp read_repository_id(repository) do
    path = Path.join(repository.runtime_dir, "repository.json")
    if File.exists?(path), do: JSON.decode!(File.read!(path))["repository_id"], else: nil
  end

  defp atomize_fact_keys(map) when is_map(map) do
    %{
      facts: Map.get(map, "facts", %{}),
      artifacts: Map.get(map, "artifacts", []),
      decisions: Map.get(map, "decisions", %{}),
      authorities: Map.get(map, "authorities", [])
    }
  end

  defp q(value), do: SQLite.quote(value)
end
