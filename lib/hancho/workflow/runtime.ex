defmodule Hancho.Workflow.Runtime do
  @moduledoc "Runs one sequential workflow as an OTP state machine."

  @behaviour :gen_statem

  alias Hancho.Log.Event
  alias Hancho.Workflow.{Params, Result}

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
          caller: nil,
          registry: Hancho.Workflow.Registry,
          executor: Hancho.Workflow.Executor,
          store_api: Hancho.Workflow.Store,
          log: :disabled,
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
    scope = %{"input" => data.input, "steps" => data.outputs, "run" => %{"id" => data.run_id}}

    with :ok <- data.store_api.start_step(data.store, data.run_id, data.index, step, step.params),
         :ok <- audit(data, "Step started: #{step.name}", "workflow.step_started", step),
         {:ok, params} <- Params.resolve(step.params, scope),
         {:ok, action} <- data.registry.fetch(step.action),
         {:ok, result} <- data.executor.run(action, params, action_context(data, step)),
         true <- is_map(result) || {:error, "Action result must be a map."} do
      result = Event.normalize(result)
      outputs = Map.put(data.outputs, step.name, result)

      with :ok <-
             data.store_api.complete_step(data.store, data.run_id, data.index, result, outputs) do
        audit(data, "Step completed: #{step.name}", "workflow.step_completed", step)
        advance(%{data | outputs: outputs})
      else
        {:error, reason} -> stop(data, step, reason)
      end
    else
      {:error, reason} -> stop(data, step, reason)
    end
  end

  def handle_event({:call, from}, :run, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :already_started}}]}
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
        error: error
      })

    result
  end

  defp action_context(data, step) do
    %{
      run_id: data.run_id,
      step: step.name,
      log: data.log,
      services: data.services,
      effect_store: %{
        api: data.store_api,
        store: data.store,
        run_id: data.run_id,
        step_position: data.index
      }
    }
  end

  defp step_name(data), do: data.definition.steps |> Enum.at(data.index) |> Map.fetch!(:name)

  defp audit(data, message, event, options \\ [])

  defp audit(data, message, event, %Hancho.Workflow.Step{} = step) do
    audit(data, message, event, metadata: %{step: step.name, action: step.action})
  end

  defp audit(data, message, event, options) do
    _result = Hancho.Log.write(data.log, message, Keyword.put(options, :event, event))
    :ok
  end
end
