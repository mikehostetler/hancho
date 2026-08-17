defmodule Hancho.Workflow.Runtime do
  @moduledoc "Runs one sequential workflow as an OTP state machine."

  @behaviour :gen_statem

  alias Hancho.Log.Event
  alias Hancho.Workflow.{Artifacts, Params, Repair, Result}

  @spec start_link(map()) :: :gen_statem.start_ret()
  def start_link(arguments), do: :gen_statem.start_link(__MODULE__, arguments, [])

  @spec run(pid()) :: Result.t()
  def run(pid), do: :gen_statem.call(pid, :run, :infinity)

  @impl true
  def callback_mode, do: :handle_event_function

  @impl true
  def init(arguments) do
    data =
      Map.merge(
        %{
          index: 0,
          outputs: %{},
          artifacts: %{},
          repairs: [],
          caller: nil,
          registry: Hancho.Workflow.Registry,
          executor: Hancho.Workflow.Executor,
          store_api: Hancho.Workflow.Store,
          log: :disabled,
          verbose: false,
          services: %{}
        },
        arguments
      )

    {:ok, :ready, data}
  end

  @impl true
  def handle_event({:call, from}, :run, :ready, data) do
    {:next_state, step_name(data), %{data | caller: from}, [{:next_event, :internal, :execute}]}
  end

  def handle_event(:internal, :execute, _state, data) do
    step = Enum.at(data.definition.steps, data.index)

    with :ok <- data.store_api.start_step(data.store, data.run_id, data.index, step, step.params),
         :ok <- audit(data, "Step started: #{step.name}", "workflow.step_started", step) do
      execute_step(data, step)
    else
      {:error, reason} -> stop(data, step, reason)
    end
  end

  def handle_event(:internal, :retry_step, _state, data) do
    step = Enum.at(data.definition.steps, data.index)
    execute_step(data, step)
  end

  def handle_event({:call, from}, :run, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_started}}]}
  end

  defp execute_step(data, step) do
    scope = %{"input" => data.input, "steps" => data.outputs, "run" => %{"id" => data.run_id}}

    with {:ok, params} <- Params.resolve(step.params, scope),
         {:ok, action} <- data.registry.fetch(step.action) do
      execute_action(data, step, action, params)
    else
      {:error, reason} -> handle_failure(data, step, %{}, reason)
    end
  end

  defp execute_action(data, step, action, params) do
    case data.executor.run(action, params, action_context(data, step)) do
      {:ok, result} when is_map(result) -> complete_step(data, step, result)
      {:ok, _result} -> handle_failure(data, step, params, "Action result must be a map.")
      {:error, reason} -> handle_failure(data, step, params, reason)
    end
  end

  defp complete_step(data, step, result) do
    result = Event.normalize(result)
    outputs = Map.put(data.outputs, step.name, result)
    repairs = Repair.recover_open(data.repairs, step.name)

    artifacts =
      data.artifacts
      |> Artifacts.put(step.action, result)
      |> put_repairs(repairs)

    with :ok <- recover_open_repairs(data),
         :ok <- data.store_api.complete_step(data.store, data.run_id, data.index, result, outputs) do
      audit(data, "Step completed: #{step.name}", "workflow.step_completed", step)
      advance(%{data | outputs: outputs, artifacts: artifacts, repairs: repairs})
    else
      {:error, reason} -> stop(%{data | repairs: repairs, artifacts: artifacts}, step, reason)
    end
  end

  defp handle_failure(data, step, params, reason) do
    case Repair.decision(step, reason, data.repairs) do
      :stop ->
        stop(data, step, reason)

      {:exhausted, code, attempts} ->
        error = Repair.exhausted_error(reason, code, attempts, step.on_error.max_attempts)
        stop(data, step, error)

      {:repair, attempt, resume?, code} ->
        run_repair(data, step, params, reason, code, attempt, resume?)
    end
  end

  defp run_repair(data, step, params, reason, code, attempt, resume?) do
    case Repair.prepare(step, params, reason, data.artifacts, data.input, attempt) do
      {:ok, repair_params, record} ->
        {repair_params, record} =
          resume_values(repair_params, record, data.repairs, step, resume?)

        repairs = if resume?, do: data.repairs, else: data.repairs ++ [record]
        repair_data = %{data | repairs: repairs, artifacts: put_repairs(data.artifacts, repairs)}

        with :ok <- begin_repair(repair_data, record, resume?),
             :ok <-
               audit_repair(
                 repair_data,
                 step,
                 "started",
                 attempt,
                 step.on_error.max_attempts,
                 code
               ) do
          execute_repair(repair_data, step, repair_params, reason, code, attempt)
        else
          {:error, repair_error} ->
            fail_repair_and_stop(repair_data, step, reason, code, attempt, repair_error)
        end

      {:error, repair_error} ->
        error = Repair.failed_error(reason, code, attempt, repair_error)
        stop(data, step, error)
    end
  end

  defp execute_repair(data, step, params, reason, code, attempt) do
    context = action_context(data, step, :repair)

    case data.executor.run(Hancho.Actions.Implement, params, context) do
      {:ok, result} when is_map(result) ->
        complete_repair_and_retry(data, step, result, reason, code, attempt)

      {:ok, result} ->
        fail_repair_and_stop(
          data,
          step,
          reason,
          code,
          attempt,
          {:invalid_repair_result, result}
        )

      {:error, repair_error} ->
        fail_repair_and_stop(data, step, reason, code, attempt, repair_error)
    end
  end

  defp complete_repair_and_retry(data, step, result, reason, code, attempt) do
    result = Event.normalize(result)

    with :ok <- complete_repair(data, attempt, result),
         :ok <-
           audit_repair(
             data,
             step,
             "completed",
             attempt,
             step.on_error.max_attempts,
             code
           ) do
      repairs = Repair.complete(data.repairs, step.name, attempt, result)
      artifacts = put_repairs(data.artifacts, repairs)
      next_data = %{data | repairs: repairs, artifacts: artifacts}

      audit(next_data, "Retrying step after repair: #{step.name}", "workflow.step_retried",
        metadata: %{step: step.name, repair_attempt: attempt}
      )

      {:next_state, step.name, next_data, [{:next_event, :internal, :retry_step}]}
    else
      {:error, repair_error} ->
        fail_repair_and_stop(data, step, reason, code, attempt, repair_error)
    end
  end

  defp fail_repair_and_stop(data, step, reason, code, attempt, repair_error) do
    persisted_error = fail_repair(data, attempt, repair_error)
    repairs = Repair.fail(data.repairs, step.name, attempt, persisted_error)
    artifacts = put_repairs(data.artifacts, repairs)

    audit_repair(
      data,
      step,
      "failed",
      attempt,
      step.on_error.max_attempts,
      code,
      error: persisted_error
    )

    error = Repair.failed_error(reason, code, attempt, persisted_error)
    stop(%{data | repairs: repairs, artifacts: artifacts}, step, error)
  end

  defp advance(data) do
    next_index = data.index + 1

    if next_index == length(data.definition.steps) do
      case data.store_api.complete_run(data.store, data.run_id, data.outputs) do
        :ok ->
          audit(data, "Workflow completed", "workflow.completed")
          result = result(data, :completed, nil, nil)
          {:stop_and_reply, :normal, [{:reply, data.caller, result}], data}

        {:error, reason} ->
          step = Enum.at(data.definition.steps, data.index)
          stop(data, step, reason)
      end
    else
      next_data = %{data | index: next_index}
      {:next_state, step_name(next_data), next_data, [{:next_event, :internal, :execute}]}
    end
  end

  defp stop(data, step, reason) do
    error = Event.normalize(reason)
    persisted_error = stop_transition(data, step, error)

    audit(data, "Step stopped: #{step.name}", "workflow.stopped",
      level: :error,
      metadata: %{step: step.name, error: persisted_error}
    )

    result = result(data, :stopped, step.name, persisted_error)
    {:stop_and_reply, :normal, [{:reply, data.caller, result}], data}
  end

  defp stop_transition(data, step, error) do
    case data.store_api.stop_run_and_step(
           data.store,
           data.run_id,
           data.index,
           step.name,
           error
         ) do
      :ok ->
        error

      {:error, reason} ->
        Event.normalize(%{cause: error, state_transition_failed: reason})
    end
  end

  defp result(data, status, current_step, error) do
    {:ok, result} =
      Result.new(%{
        run_id: data.run_id,
        workflow: data.definition.name,
        status: status,
        current_step: current_step,
        outputs: data.outputs,
        artifacts: data.artifacts,
        error: error
      })

    result
  end

  defp action_context(data, step, activity \\ :workflow) do
    %{
      run_id: data.run_id,
      step: step.name,
      activity: activity,
      log: data.log,
      verbose: data.verbose,
      artifacts: data.artifacts,
      services: data.services,
      effect_store: %{
        api: data.store_api,
        store: data.store,
        run_id: data.run_id,
        step_position: data.index
      }
    }
  end

  defp resume_values(params, record, repairs, step, true) do
    existing =
      Enum.find(repairs, fn repair ->
        repair["step"] == step.name and repair["status"] == "running"
      end)

    case existing do
      %{"prompt" => prompt} -> {Map.put(params, :prompt, prompt), existing}
      _other -> {params, record}
    end
  end

  defp resume_values(params, record, _repairs, _step, false), do: {params, record}

  defp begin_repair(_data, _record, true), do: :ok

  defp begin_repair(data, record, false) do
    if function_exported?(data.store_api, :begin_step_repair, 4) do
      data.store_api.begin_step_repair(data.store, data.run_id, data.index, record)
    else
      :ok
    end
  end

  defp complete_repair(data, attempt, result) do
    if function_exported?(data.store_api, :complete_step_repair, 5) do
      data.store_api.complete_step_repair(data.store, data.run_id, data.index, attempt, result)
    else
      :ok
    end
  end

  defp fail_repair(data, attempt, repair_error) do
    if function_exported?(data.store_api, :fail_step_repair, 5) do
      case data.store_api.fail_step_repair(
             data.store,
             data.run_id,
             data.index,
             attempt,
             repair_error
           ) do
        :ok -> repair_error
        {:error, reason} -> %{cause: repair_error, repair_state_transition_failed: reason}
      end
    else
      repair_error
    end
  end

  defp recover_open_repairs(data) do
    if function_exported?(data.store_api, :recover_step_repairs, 3) do
      data.store_api.recover_step_repairs(data.store, data.run_id, data.index)
    else
      :ok
    end
  end

  defp put_repairs(artifacts, []), do: artifacts
  defp put_repairs(artifacts, repairs), do: Map.put(artifacts, "repairs", repairs)

  defp audit_repair(data, step, status, attempt, maximum, code, options \\ []) do
    level = Keyword.get(options, :level, if(status == "failed", do: :error, else: :info))

    metadata = %{
      step: step.name,
      action: step.action,
      status: status,
      repair_attempt: attempt,
      max_attempts: maximum,
      error_code: code,
      provider: step.on_error.repair_with
    }

    metadata =
      case Keyword.fetch(options, :error) do
        {:ok, error} -> Map.put(metadata, :error, Event.normalize(error))
        :error -> metadata
      end

    audit(
      data,
      "Repair attempt #{attempt}/#{maximum} #{status} for #{step.name}",
      "workflow.repair_#{status}",
      level: level,
      metadata: metadata
    )
  end

  defp step_name(data), do: data.definition.steps |> Enum.at(data.index) |> Map.fetch!(:name)

  defp audit(data, message, event, options \\ [])

  defp audit(data, message, event, %Hancho.Workflow.Step{} = step) do
    audit(data, message, event, metadata: %{step: step.name, action: step.action})
  end

  defp audit(data, message, event, options) do
    Hancho.Audit.write(data.log, message, Keyword.put(options, :event, event))
  end
end
