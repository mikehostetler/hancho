defmodule Hancho.Operations do
  @moduledoc "User-requested work-order events and durable decisions."

  alias Hancho.Workflow.{Event, Registry}
  alias Hancho.{BuildRunner, Error, Journal, Repository, Runner}

  @spec decide(Repository.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def decide(repository, decision_id, answer, actor, reason) do
    with {:ok, decision} <- Journal.decide(repository, decision_id, answer, actor, reason),
         {:ok, _event} <-
           Journal.record_event(repository, decision["run_id"], "decision_#{answer}",
             actor: actor,
             reason: reason,
             payload: %{decision_id: decision_id, kind: decision["kind"]}
           ) do
      {:ok, decision}
    end
  end

  @spec cancel(Repository.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def cancel(repository, run_id, actor, reason) do
    with {:ok, work_order} <- Journal.get_work_order(repository, run_id) do
      cond do
        work_order["state"] == "cancelled" ->
          {:ok, work_order}

        work_order["status"] == "complete" ->
          {:error,
           %Error{
             code: :run_terminal,
             exit_status: 75,
             message: "Work order '#{run_id}' is complete and cannot be cancelled."
           }}

        true ->
          with {:ok, definition} <-
                 Registry.fetch(work_order["workflow_name"], work_order["workflow_version"]),
               {:ok, result} <-
                 Journal.transition(repository, run_id, definition, %Event{
                   name: "cancel_requested",
                   expected_state: work_order["state"],
                   actor: actor,
                   reason: reason
                 }) do
            {:ok, result.work_order}
          end
      end
    end
  end

  @spec resume(Repository.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(repository, run_id) do
    with {:ok, work_order} <- Journal.get_work_order(repository, run_id) do
      case work_order["workflow_name"] do
        "walking_skeleton" ->
          Runner.resume(repository, run_id)

        "build" ->
          BuildRunner.resume(repository, run_id)

        "plan" ->
          Hancho.PlanRunner.resume(repository, run_id)

        workflow ->
          {:error,
           %Error{
             code: :resume_not_supported,
             exit_status: 69,
             message: "Workflow '#{workflow}' does not support resume."
           }}
      end
    end
  end
end
