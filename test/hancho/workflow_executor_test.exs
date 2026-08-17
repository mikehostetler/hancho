defmodule Hancho.WorkflowExecutorTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.Executor

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

  test "uses a validated timeout_ms parameter as the outer action timeout" do
    assert {:ok, %{remaining_ms: remaining}} =
             Executor.run(TimedAction, %{"timeout_ms" => 120_000}, %{})

    assert remaining > 100_000
  end
end
