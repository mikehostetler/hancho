defmodule Hancho.HarnessTest do
  use ExUnit.Case, async: false

  test "starts Jido.Harness through the shared command runtime" do
    assert Hancho.Harness.ensure_started() == :ok
    assert is_binary(Jido.Harness.version())
    assert Jido.Harness.providers() != []
  end
end
