defmodule Hancho.Runner do
  @moduledoc "Runs one work order in the foreground through the shared engine and journal."

  alias Hancho.Harness.Executor
  alias Hancho.Workflow.{Event, Registry}
  alias Hancho.{Config, Error, Journal, Repository}

  @spec run(Repository.t(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(repository, workflow_name, work_ref, options \\ [])

  def run(repository, "plan", work_ref, options),
    do: Hancho.PlanRunner.run(repository, work_ref, options)

  def run(repository, "audit", work_ref, options),
    do: Hancho.AuditRunner.run(repository, work_ref, options)

  def run(repository, workflow_name, work_ref, options) do
    with {:ok, config} <- Config.load(repository),
         {:ok, definition} <- Registry.fetch(workflow_name),
         :ok <- supported(definition),
         {:ok, work_order} <-
           Journal.create_work_order(repository, config, definition, work_ref, %{
             actor: Keyword.get(options, :actor, actor()),
             reason: "Work order submitted"
           }),
         {:ok, started} <-
           Journal.transition(
             repository,
             work_order["id"],
             definition,
             %Event{
               name: "start",
               expected_state: definition.initial_state,
               actor: actor(),
               reason: "Work released"
             }
           ),
         {:ok, outcome} <-
           execute_walking_skeleton(repository, config, definition, started.work_order, options) do
      {:ok, outcome}
    end
  end

  @spec resume(Repository.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resume(repository, run_id) do
    with {:ok, config} <- Config.load(repository),
         {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         true <-
           work_order["workflow_name"] == "walking_skeleton" and work_order["state"] == "stopped",
         {:ok, definition} <- Registry.fetch("walking_skeleton", work_order["workflow_version"]),
         {:ok, resumed} <-
           Journal.transition(repository, run_id, definition, %Event{
             name: "resume_requested",
             expected_state: "stopped",
             actor: actor(),
             reason: "User requested safe resume"
           }),
         {:ok, outcome} <-
           execute_walking_skeleton(repository, config, definition, resumed.work_order,
             attempt: 2
           ) do
      {:ok, outcome}
    else
      false ->
        {:error,
         %Error{
           code: :resume_not_permitted,
           exit_status: 75,
           message: "Walking-skeleton work order '#{run_id}' is not in a resumable stopped state."
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp execute_walking_skeleton(repository, config, definition, work_order, options) do
    prompt =
      Keyword.get(
        options,
        :prompt,
        "Inspect the repository. Return a successful read-only result."
      )

    case Executor.run_station(
           repository,
           config,
           definition,
           work_order,
           "operate",
           prompt,
           options
         ) do
      {:ok, %{result: %{status: "success"}} = execution} ->
        with {:ok, final} <-
               Journal.transition(repository, work_order["id"], definition, %Event{
                 name: "harness_succeeded",
                 expected_state: "operating",
                 actor: "harness",
                 reason: "Harness completed successfully"
               }) do
          {:ok, %{work_order: final.work_order, execution: execution}}
        end

      {:ok, execution} ->
        stop_after_harness_failure(repository, definition, work_order, execution)

      {:error, error} ->
        stop_after_harness_failure(repository, definition, work_order, %{error: error})
    end
  end

  defp stop_after_harness_failure(repository, definition, work_order, execution) do
    with {:ok, final} <-
           Journal.transition(repository, work_order["id"], definition, %Event{
             name: "harness_failed",
             expected_state: "operating",
             actor: "hancho",
             reason: "Harness did not complete successfully"
           }) do
      {:ok, %{work_order: final.work_order, execution: execution}}
    end
  end

  defp supported(%{name: "walking_skeleton"}), do: :ok

  defp supported(definition) do
    {:error,
     %Error{
       code: :workflow_not_executable,
       exit_status: 69,
       message:
         "Workflow '#{definition.name}.v#{definition.version}' is installed but its action runner is not complete."
     }}
  end

  defp actor do
    System.get_env("USER") || "local-user"
  end
end
