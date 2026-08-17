defmodule Hancho.Workflow.Store do
  @moduledoc "Stores durable workflow state in the repository-local Bedrock cluster."

  alias Hancho.Log.Event
  alias Hancho.State.{Bedrock, Repo}
  alias Hancho.Workflow.{EffectRecord, QueueRecord, RunRecord, StepRecord}

  @prefix "hancho/workflow/runs/"
  @queue_prefix "hancho/workflow/queues/"
  @active_queue_key "hancho/workflow/queues/active"

  @spec open(String.t()) :: {:ok, String.t()} | {:error, term()}
  def open(path) do
    case Bedrock.open(path) do
      :ok -> {:ok, Path.expand(path)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec close(String.t()) :: :ok | {:error, term()}
  def close(store), do: Bedrock.flush(store)

  @spec create_run(String.t(), String.t(), Hancho.Workflow.Definition.t(), map(), map()) ::
          :ok | {:error, term()}
  def create_run(store, id, definition, input, workflow_source) do
    transact(store, fn ->
      key = run_key(id)

      if Repo.get(key) do
        Repo.rollback(:already_exists)
      else
        put_run(
          key,
          %{
            "record_version" => 1,
            "transition_version" => 0,
            "id" => id,
            "workflow_name" => definition.name,
            "workflow_version" => definition.version,
            "workflow_source_path" => workflow_source.path,
            "workflow_yaml" => workflow_source.yaml,
            "workflow_sha256" => workflow_source.sha256,
            "status" => "running",
            "current_step" => nil,
            "input_json" => encode!(input),
            "started_at" => now(),
            "finished_at" => nil,
            "error_json" => nil
          }
        )
      end
    end)
  end

  @spec start_step(String.t(), String.t(), non_neg_integer(), Hancho.Workflow.Step.t(), map()) ::
          :ok | {:error, term()}
  def start_step(store, run_id, position, step, params) do
    update_run(store, run_id, fn run ->
      if run["status"] != "running" do
        {:error, :run_not_running}
      else
        key = step_key(run_id, position)

        stored_step = %{
          "record_version" => 1,
          "transition_version" => 0,
          "position" => position,
          "name" => step.name,
          "action" => step.action,
          "status" => "running",
          "params_json" => encode!(params),
          "operation_json" => nil,
          "result_json" => nil,
          "started_at" => now(),
          "finished_at" => nil,
          "error_json" => nil
        }

        case Repo.get(key) do
          nil ->
            put_step(key, stored_step)
            Map.put(run, "current_step", step.name)

          encoded ->
            case decode_record(encoded, StepRecord) do
              {:ok, %{"status" => "retry_pending"} = existing} ->
                put_step(key, Map.put(stored_step, "operation_json", existing["operation_json"]))
                Map.put(run, "current_step", step.name)

              _other ->
                Repo.rollback({:step_already_exists, position})
            end
        end
      end
    end)
  end

  @spec retry_run(String.t(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def retry_run(store, run_id, position) do
    transact(store, fn ->
      run_key = run_key(run_id)
      step_key = step_key(run_id, position)

      with {:ok, run} <- get_run(run_key),
           :ok <- status_in(run, ["stopped", "running", "recovery_required"], :run_not_resumable),
           {:ok, step} <- get_step(step_key),
           :ok <-
             status_in(step, ["stopped", "running", "recovery_required"], :step_not_resumable) do
        retried_run =
          run
          |> Map.put("status", "running")
          |> Map.put("finished_at", nil)
          |> Map.put("error_json", nil)

        retried_step =
          step
          |> Map.put("status", "retry_pending")
          |> Map.put("finished_at", nil)
          |> Map.put("error_json", nil)

        put_run(run_key, bump(retried_run))
        put_step(step_key, bump(retried_step))
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec complete_step(String.t(), String.t(), non_neg_integer(), map(), map()) ::
          :ok | {:error, term()}
  def complete_step(store, run_id, position, result, _outputs) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running"], :run_not_running),
           :ok <- status_in(step, ["running"], :step_not_running) do
        completed_step =
          step
          |> Map.put("status", "completed")
          |> Map.put("result_json", encode!(result))
          |> Map.put("finished_at", now())

        {run, completed_step}
      end
    end)
  end

  @spec complete_run(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def complete_run(store, run_id, _outputs) do
    transact(store, fn ->
      key = run_key(run_id)

      with {:ok, run} <- get_run(key),
           :ok <- status_in(run, ["running"], :run_not_running),
           {:ok, steps} <- read_steps(run_id),
           true <-
             (steps != [] and Enum.all?(steps, &(&1["status"] == "completed"))) ||
               Repo.rollback(:run_has_incomplete_steps) do
        completed =
          run
          |> Map.put("status", "completed")
          |> Map.put("current_step", nil)
          |> Map.put("finished_at", now())

        put_run(key, bump(completed))
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fail_step(String.t(), String.t(), non_neg_integer(), term()) :: :ok | {:error, term()}
  def fail_step(store, run_id, position, error) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(step, ["running", "recovery_required"], :step_not_running) do
        stopped_step =
          step
          |> Map.put("status", "stopped")
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        {run, stopped_step}
      end
    end)
  end

  @spec fail_run(String.t(), String.t(), String.t(), map(), term()) :: :ok | {:error, term()}
  def fail_run(store, run_id, step_name, _outputs, error) do
    update_run(store, run_id, fn run ->
      with :ok <- status_in(run, ["running", "recovery_required"], :run_not_running) do
        run
        |> Map.put("status", "stopped")
        |> Map.put("current_step", step_name)
        |> Map.put("error_json", encode!(error))
        |> Map.put("finished_at", now())
      end
    end)
  end

  @spec stop_run_and_step(String.t(), String.t(), non_neg_integer(), String.t(), term()) ::
          :ok | {:error, term()}
  def stop_run_and_step(store, run_id, position, step_name, error) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running", "recovery_required"], :run_not_running),
           :ok <- status_in(step, ["running", "recovery_required"], :step_not_running) do
        stopped_step =
          step
          |> Map.put("status", "stopped")
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        stopped_run =
          run
          |> Map.put("status", "stopped")
          |> Map.put("current_step", step_name)
          |> Map.put("error_json", encode!(error))
          |> Map.put("finished_at", now())

        {stopped_run, stopped_step}
      end
    end)
  end

  @spec fetch_run(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_run(store, id) do
    transact(store, fn ->
      case Repo.get(run_key(id)) do
        nil ->
          Repo.rollback(:not_found)

        encoded ->
          with {:ok, run} <- decode_record(encoded, RunRecord),
               {:ok, steps} <- read_steps(id) do
            outputs =
              steps
              |> Enum.filter(&(&1["status"] == "completed"))
              |> Map.new(fn step ->
                {step["name"], decode_optional!(step["result_json"])}
              end)

            {:ok, Map.put(run, "outputs_json", encode!(outputs))}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  @spec begin_effect(String.t(), String.t(), non_neg_integer(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def begin_effect(store, run_id, position, key, kind, intent) do
    transact(store, fn ->
      effect_key = effect_key(run_id, position, key)
      intent_json = encode!(intent)

      with {:ok, run} <- get_run(run_key(run_id)),
           :ok <- status_in(run, ["running"], :run_not_running),
           {:ok, step} <- get_step(step_key(run_id, position)),
           :ok <- status_in(step, ["running"], :step_not_running) do
        case Repo.get(effect_key) do
          nil ->
            effect = %{
              "record_version" => 1,
              "transition_version" => 0,
              "run_id" => run_id,
              "step_position" => position,
              "key" => key,
              "kind" => kind,
              "status" => "intended",
              "intent_json" => intent_json,
              "receipt_json" => nil,
              "attempt" => 1,
              "started_at" => now(),
              "applied_at" => nil,
              "error_json" => nil
            }

            put_effect(effect_key, effect)
            {:ok, effect}

          encoded ->
            with {:ok, effect} <- decode_record(encoded, EffectRecord),
                 :ok <- same_effect(effect, kind, intent_json) do
              retried =
                effect
                |> Map.update!("attempt", &(&1 + 1))
                |> Map.put("error_json", nil)
                |> bump()

              put_effect(effect_key, retried)
              {:ok, retried}
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec complete_effect(String.t(), String.t(), non_neg_integer(), String.t(), map()) ::
          :ok | {:error, term()}
  def complete_effect(store, run_id, position, key, receipt) do
    transact(store, fn ->
      effect_key = effect_key(run_id, position, key)
      receipt_json = encode!(receipt)

      with {:ok, effect} <- get_effect(effect_key) do
        case effect do
          %{"status" => "intended"} ->
            applied =
              effect
              |> Map.put("status", "applied")
              |> Map.put("receipt_json", receipt_json)
              |> Map.put("applied_at", now())
              |> Map.put("error_json", nil)

            put_effect(effect_key, bump(applied))

          %{"status" => "applied", "receipt_json" => ^receipt_json} ->
            :ok

          %{"status" => "applied"} ->
            Repo.rollback(:effect_receipt_changed)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fail_effect(String.t(), String.t(), non_neg_integer(), String.t(), term()) ::
          :ok | {:error, term()}
  def fail_effect(store, run_id, position, key, error) do
    transact(store, fn ->
      effect_key = effect_key(run_id, position, key)

      with {:ok, effect} <- get_effect(effect_key),
           :ok <- status_in(effect, ["intended"], :effect_already_applied) do
        put_effect(effect_key, effect |> Map.put("error_json", encode!(error)) |> bump())
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec list_steps(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_steps(store, run_id) do
    transact(store, fn ->
      if Repo.get(run_key(run_id)) do
        case read_steps(run_id) do
          {:ok, steps} -> {:ok, steps}
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback(:not_found)
      end
    end)
  end

  @spec record_step_operation(
          String.t(),
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          map()
        ) :: :ok | {:error, term()}
  def record_step_operation(store, run_id, position, kind, id, metadata) do
    update_run_and_step(store, run_id, position, fn run, step ->
      with :ok <- status_in(run, ["running"], :run_not_running),
           :ok <- status_in(step, ["running"], :step_not_running) do
        operation = encode!(%{kind: kind, id: id, metadata: metadata})
        {run, Map.put(step, "operation_json", operation)}
      end
    end)
  end

  @spec fetch_step_operation(String.t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def fetch_step_operation(store, run_id, position, kind) do
    transact(store, fn ->
      with {:ok, step} <- get_step(step_key(run_id, position)) do
        case decode_optional(step["operation_json"]) do
          {:ok, nil} -> {:ok, nil}
          {:ok, %{"kind" => ^kind} = operation} -> {:ok, operation}
          {:ok, %{"kind" => other}} -> Repo.rollback({:operation_kind_changed, other, kind})
          {:ok, other} -> Repo.rollback({:invalid_step_operation, other})
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec create_queue(String.t(), String.t(), String.t(), String.t(), [map()], map()) ::
          :ok | {:error, term()}
  def create_queue(store, id, workflow, source, items, repository_state) do
    transact(store, fn ->
      if active = Repo.get(@active_queue_key) do
        Repo.rollback({:queue_already_running, active})
      else
        queue = %{
          "record_version" => 1,
          "transition_version" => 0,
          "id" => id,
          "workflow_name" => workflow,
          "source" => source,
          "status" => "running",
          "repository" => repository_state.repository,
          "expected_branch" => repository_state.branch,
          "expected_head" => repository_state.head,
          "expected_worktrees" => Map.get(repository_state, :expected_worktrees, []),
          "current_position" => 0,
          "current_run_id" => nil,
          "items" =>
            Enum.map(items, fn item ->
              %{
                "position" => item.position,
                "issue_id" => item.issue_id,
                "run_id" => item.run_id,
                "status" => "pending",
                "phase" => "selected",
                "error" => nil
              }
            end),
          "started_at" => now(),
          "finished_at" => nil,
          "error" => nil
        }

        put_queue(queue_key(id), queue)
        Repo.put(@active_queue_key, id)
      end
    end)
  end

  @spec start_queue_item(String.t(), String.t(), non_neg_integer()) ::
          :ok | {:error, term()}
  def start_queue_item(store, queue_id, position) do
    update_queue(store, queue_id, fn queue ->
      with :ok <- queue_position(queue, position),
           {:ok, item} <- queue_item(queue, position),
           :ok <- item_status(item, "pending") do
        queue
        |> put_queue_item(
          position,
          item |> Map.put("status", "running") |> Map.put("phase", "child_starting")
        )
        |> Map.put("current_run_id", item["run_id"])
      end
    end)
  end

  @spec complete_queue_item(String.t(), String.t(), non_neg_integer(), String.t()) ::
          :ok | {:error, term()}
  def complete_queue_item(store, queue_id, position, expected_head) do
    update_queue(store, queue_id, fn queue ->
      with :ok <- queue_position(queue, position),
           {:ok, item} <- queue_item(queue, position),
           :ok <- item_status(item, "running") do
        queue
        |> put_queue_item(
          position,
          item
          |> Map.put("status", "completed")
          |> Map.put("phase", "completed")
          |> Map.put("error", nil)
        )
        |> Map.put("expected_head", expected_head)
        |> Map.put("current_position", position + 1)
        |> Map.put("current_run_id", nil)
      end
    end)
  end

  @spec stop_queue_item(String.t(), String.t(), non_neg_integer(), term()) ::
          :ok | {:error, term()}
  def stop_queue_item(store, queue_id, position, error) do
    transact(store, fn ->
      with {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <- queue_position(queue, position),
           {:ok, item} <- queue_item(queue, position),
           :ok <- status_in(item, ["pending", "running"], :queue_item_not_stoppable) do
        stopped_item =
          item
          |> Map.put("status", "stopped")
          |> Map.put("phase", "child_stopped")
          |> Map.put("error", Event.normalize(error))

        queue =
          queue
          |> put_queue_item(position, stopped_item)
          |> stop_queue(error)

        put_queue(queue_key(queue_id), bump(queue))
        Repo.clear(@active_queue_key)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec resume_queue(String.t(), String.t()) :: :ok | {:error, term()}
  def resume_queue(store, queue_id) do
    transact(store, fn ->
      active = Repo.get(@active_queue_key)

      with :ok <- active_queue_available(active, queue_id),
           {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <-
             status_in(queue, ["stopped", "running", "recovery_required"], :queue_not_resumable),
           position = queue["current_position"],
           {:ok, item} <- queue_item(queue, position),
           :ok <- status_in(item, ["pending", "stopped", "running"], :queue_item_not_resumable) do
        resumed_item =
          item
          |> Map.put("status", "running")
          |> Map.put("phase", "child_starting")
          |> Map.put("error", nil)

        resumed_queue =
          queue
          |> put_queue_item(position, resumed_item)
          |> Map.put("status", "running")
          |> Map.put("current_run_id", item["run_id"])
          |> Map.put("finished_at", nil)
          |> Map.put("error", nil)

        put_queue(queue_key(queue_id), bump(resumed_queue))
        Repo.put(@active_queue_key, queue_id)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fail_queue(String.t(), String.t(), term()) :: :ok | {:error, term()}
  def fail_queue(store, queue_id, error) do
    transact(store, fn ->
      with {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <- status_in(queue, ["running", "recovery_required"], :queue_not_running) do
        put_queue(queue_key(queue_id), queue |> stop_queue(error) |> bump())
        Repo.clear(@active_queue_key)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec complete_queue(String.t(), String.t()) :: :ok | {:error, term()}
  def complete_queue(store, queue_id) do
    transact(store, fn ->
      with {:ok, queue} <- get_queue(queue_key(queue_id)),
           :ok <- status_in(queue, ["running"], :queue_not_running),
           true <-
             Enum.all?(queue["items"], &(&1["status"] == "completed")) ||
               Repo.rollback(:queue_has_incomplete_items) do
        completed =
          queue
          |> Map.put("status", "completed")
          |> Map.put("current_run_id", nil)
          |> Map.put("finished_at", now())

        put_queue(queue_key(queue_id), bump(completed))
        Repo.clear(@active_queue_key)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec fetch_queue(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_queue(store, id) do
    transact(store, fn ->
      case get_queue(queue_key(id)) do
        {:ok, queue} -> {:ok, queue}
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_run(store, run_id, function) do
    transact(store, fn ->
      key = run_key(run_id)

      with {:ok, run} <- get_run(key) do
        case function.(run) do
          %{} = updated -> put_run(key, bump(updated))
          {:error, reason} -> Repo.rollback(reason)
          other -> Repo.rollback({:invalid_run_transition, other})
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_queue(store, queue_id, function) do
    transact(store, fn ->
      key = queue_key(queue_id)

      with {:ok, queue} <- get_queue(key) do
        case function.(queue) do
          %{} = updated -> put_queue(key, bump(updated))
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp update_run_and_step(store, run_id, position, function) do
    transact(store, fn ->
      run_key = run_key(run_id)
      step_key = step_key(run_id, position)

      with {:ok, run} <- get_run(run_key),
           {:ok, step} <- get_step(step_key) do
        case function.(run, step) do
          {:error, reason} ->
            Repo.rollback(reason)

          {updated_run, updated_step} ->
            put_run(run_key, bump(updated_run))
            put_step(step_key, bump(updated_step))
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp get_run(key), do: get_record(key, RunRecord)
  defp get_step(key), do: get_record(key, StepRecord)
  defp get_queue(key), do: get_record(key, QueueRecord)
  defp get_effect(key), do: get_record(key, EffectRecord)

  defp get_record(key, module) do
    case Repo.get(key) do
      nil -> {:error, :not_found}
      encoded -> decode_record(encoded, module)
    end
  end

  defp read_steps(run_id) do
    prefix = step_prefix(run_id)

    prefix
    |> then(&Repo.get_range({&1, &1 <> <<255>>}))
    |> Enum.reduce_while({:ok, []}, fn {_key, encoded}, {:ok, steps} ->
      case decode_record(encoded, StepRecord) do
        {:ok, step} -> {:cont, {:ok, [step | steps]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, steps} -> {:ok, Enum.sort_by(steps, & &1["position"])}
      error -> error
    end
  end

  defp run_key(run_id), do: @prefix <> encoded_id(run_id) <> "/run"
  defp queue_key(queue_id), do: @queue_prefix <> encoded_id(queue_id) <> "/queue"
  defp step_prefix(run_id), do: @prefix <> encoded_id(run_id) <> "/steps/"

  defp step_key(run_id, position) do
    step_prefix(run_id) <> String.pad_leading(Integer.to_string(position), 12, "0")
  end

  defp effect_key(run_id, position, key) do
    @prefix <>
      encoded_id(run_id) <>
      "/effects/" <>
      String.pad_leading(Integer.to_string(position), 12, "0") <>
      "/" <> encoded_id(key)
  end

  defp encoded_id(run_id), do: Base.url_encode64(run_id, padding: false)

  defp queue_position(%{"status" => "running", "current_position" => position}, position),
    do: :ok

  defp queue_position(_queue, _position), do: {:error, :invalid_queue_position}

  defp queue_item(queue, position) do
    case Enum.at(queue["items"], position) do
      nil -> {:error, :queue_item_not_found}
      item -> {:ok, item}
    end
  end

  defp item_status(%{"status" => status}, status), do: :ok
  defp item_status(_item, _status), do: {:error, :invalid_queue_item_status}

  defp status_in(%{"status" => status}, allowed, error) do
    if status in allowed, do: :ok, else: {:error, error}
  end

  defp status_in(_record, _allowed, error), do: {:error, error}

  defp active_queue_available(nil, _queue_id), do: :ok
  defp active_queue_available(queue_id, queue_id), do: :ok
  defp active_queue_available(active, _queue_id), do: {:error, {:queue_already_running, active}}

  defp same_effect(%{"kind" => kind, "intent_json" => intent_json}, kind, intent_json), do: :ok
  defp same_effect(_effect, _kind, _intent_json), do: {:error, :effect_intent_changed}

  defp put_queue_item(queue, position, item) do
    Map.update!(queue, "items", &List.replace_at(&1, position, item))
  end

  defp stop_queue(queue, error) do
    queue
    |> Map.put("status", "stopped")
    |> Map.put("error", Event.normalize(error))
    |> Map.put("finished_at", now())
  end

  defp transact(store, function), do: Bedrock.transaction(store, function)

  defp put_run(key, value), do: put_record(key, value, RunRecord)
  defp put_step(key, value), do: put_record(key, value, StepRecord)
  defp put_queue(key, value), do: put_record(key, value, QueueRecord)
  defp put_effect(key, value), do: put_record(key, value, EffectRecord)

  defp put_record(key, value, module) do
    case module.new(value) do
      {:ok, record} -> Repo.put(key, record |> module.to_map() |> encode!())
      {:error, reason} -> Repo.rollback({:invalid_state_record, module, reason})
    end
  end

  defp decode_record(value, module) do
    with {:ok, decoded} <- decode(value),
         upgraded <- upgrade_record(module, decoded),
         {:ok, record} <- module.new(upgraded) do
      {:ok, module.to_map(record)}
    else
      {:error, reason} -> {:error, {:invalid_state_record, module, reason}}
    end
  end

  defp upgrade_record(module, decoded) do
    if function_exported?(module, :upgrade, 1), do: module.upgrade(decoded), else: decoded
  end

  defp bump(record),
    do: Map.update(record, "transition_version", 1, &(&1 + 1))

  defp encode!(value), do: value |> Event.normalize() |> Jason.encode!()

  defp decode(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_state, Exception.message(reason)}}
    end
  end

  defp decode_optional!(nil), do: nil
  defp decode_optional!(value), do: Jason.decode!(value)

  defp decode_optional(nil), do: {:ok, nil}

  defp decode_optional(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, reason} -> {:error, {:invalid_state, Exception.message(reason)}}
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
