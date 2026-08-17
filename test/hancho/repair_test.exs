defmodule Hancho.RepairTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.{Repair, Step}

  test "classifies only configured verification failures and enforces the attempt limit" do
    assert {:ok, step} =
             Step.new(%{
               name: "verify",
               action: "Hancho.Actions.Verify",
               params: %{},
               on_error: %{
                 codes: ["verification_failed"],
                 repair_with: "grok",
                 max_attempts: 1,
                 retry_step: "verify"
               }
             })

    failure = "Verification failed with exit status 1. Full output: /tmp/verify.log"
    assert Repair.decision(step, failure, []) == {:repair, 1, false, "verification_failed"}
    assert Repair.decision(step, :command_timed_out, []) == :stop

    repairs = [
      %{
        "step" => "verify",
        "attempt" => 1,
        "status" => "completed"
      }
    ]

    assert Repair.decision(step, failure, repairs) == {:exhausted, "verification_failed", 1}
  end

  test "resumes an incomplete durable attempt without consuming a new attempt" do
    assert {:ok, step} =
             Step.new(%{
               name: "validate_scope",
               action: "Hancho.Actions.ValidateScope",
               params: %{},
               on_error: %{
                 codes: ["changes_outside_allowed_scope"],
                 repair_with: "grok",
                 max_attempts: 2,
                 retry_step: "validate_scope"
               }
             })

    failure = %{code: "changes_outside_allowed_scope"}
    repairs = [%{"step" => "validate_scope", "attempt" => 1, "status" => "running"}]

    assert Repair.decision(step, failure, repairs) ==
             {:repair, 1, true, "changes_outside_allowed_scope"}
  end

  test "classifies scope and verification failures wrapped by Jido" do
    assert {:ok, scope_step} =
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

    scope_failure =
      Jido.Action.Error.ExecutionFailureError.exception(
        message: "%{code: \"changes_outside_allowed_scope\"}",
        details: %{
          code: "changes_outside_allowed_scope",
          unexpected_paths: ["test/outside_scope_test.exs"]
        }
      )

    assert Repair.decision(scope_step, scope_failure, []) ==
             {:repair, 1, false, "changes_outside_allowed_scope"}

    assert {:ok, verify_step} =
             Step.new(%{
               name: "verify",
               action: "Hancho.Actions.Verify",
               params: %{},
               on_error: %{
                 codes: ["verification_failed"],
                 repair_with: "grok",
                 max_attempts: 1,
                 retry_step: "verify"
               }
             })

    verify_failure =
      Jido.Action.Error.ExecutionFailureError.exception(
        message: "Verification failed with exit status 1. Full output: /tmp/verify.log",
        details: %{}
      )

    assert Repair.decision(verify_step, verify_failure, []) ==
             {:repair, 1, false, "verification_failed"}
  end
end
