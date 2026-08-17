defmodule Hancho.WorkflowExecutorTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.{Executor, Repair, Step}

  defmodule TimedAction do
    use Jido.Action,
      name: "timed_action",
      description: "Reports its execution deadline",
      schema: Zoi.object(%{timeout_ms: Zoi.integer() |> Zoi.min(1)})

    @impl true
    def run(_params, context) do
      remaining = context.__jido_deadline_ms__ - System.monotonic_time(:millisecond)
      {:ok, %{remaining_ms: remaining}}
    end
  end

  defmodule FailingAction do
    use Jido.Action,
      name: "failing_action",
      description: "Returns a structured scope failure",
      schema: Zoi.object(%{})

    @impl true
    def run(_params, _context) do
      {:error,
       %{
         code: "changes_outside_allowed_scope",
         unexpected_paths: ["test/outside_scope_test.exs"]
       }}
    end
  end

  test "uses a validated timeout_ms parameter as the outer action timeout" do
    assert {:ok, %{remaining_ms: remaining}} =
             Executor.run(TimedAction, %{"timeout_ms" => 120_000}, %{})

    assert remaining > 100_000
  end

  test "keeps a Jido-wrapped action error repairable" do
    assert {:error, %Jido.Action.Error.ExecutionFailureError{} = error} =
             Executor.run(FailingAction, %{}, %{})

    assert {:ok, step} =
             Step.new(%{
               name: "validate_scope",
               action: "Hancho.Actions.ValidateScope",
               params: %{},
               on_error: %{
                 codes: ["changes_outside_allowed_scope"],
                 repair_with: "grok",
                 max_attempts: 1,
                 retry_step: "validate_scope"
               }
             })

    assert Repair.decision(step, error, []) ==
             {:repair, 1, false, "changes_outside_allowed_scope"}
  end
end
