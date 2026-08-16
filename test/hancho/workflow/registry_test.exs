defmodule Hancho.Workflow.RegistryTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.Registry

  test "lists valid versioned workflows" do
    assert :ok = Registry.validate_all()
    assert Enum.any?(Registry.list(), &(&1.name == "walking_skeleton" and &1.version == 1))
    assert Enum.any?(Registry.list(), &(&1.name == "build" and &1.version == 1))
  end

  test "fetches one pinned version" do
    assert {:ok, %{name: "build", version: 1}} = Registry.fetch("build", 1)
    assert {:error, %{code: :unknown_workflow}} = Registry.fetch("build", 99)
  end
end
