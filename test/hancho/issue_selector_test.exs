defmodule Hancho.Workflow.IssueSelectorTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.IssueSelector

  defmodule Beadwork do
    def ready(_options), do: {:ok, [task()]}
    def list_all(_options), do: {:ok, [epic(), task()]}

    defp epic do
      %{
        "id" => "epic",
        "type" => "epic",
        "status" => "open",
        "description" =>
          "Hancho-GitHub-Issue: https://github.test/issues/1\nHancho-GitHub-Node: root"
      }
    end

    defp task do
      %{
        "id" => "task",
        "type" => "task",
        "status" => "open",
        "parent" => "epic",
        "description" => "not mapped"
      }
    end
  end

  test "does not select a ready task without an explicit sub-issue mapping" do
    assert {:error, "Beadwork has 0 ready tasks; 1 are required."} =
             IssueSelector.select(Beadwork, "/repo", 1)
  end
end
