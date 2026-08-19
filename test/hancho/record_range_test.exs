defmodule Hancho.RecordRangeTest do
  use ExUnit.Case, async: true

  alias Hancho.Workflow.RecordRange

  test "ignores a durability marker returned outside the requested prefix" do
    prefix = "hancho/workflow/runs/run/steps/"

    rows = [
      {prefix <> "000000000000", ~s({"position":0})},
      {"hancho/internal/durability-marker", "1787153176801742"}
    ]

    assert {:ok, [%{"position" => 0}]} =
             RecordRange.decode_prefix(rows, prefix, &Jason.decode/1)
  end

  test "returns a decode error for a corrupt record inside the prefix" do
    prefix = "hancho/workflow/runs/run/steps/"
    rows = [{prefix <> "000000000000", "not-json"}]

    assert {:error, %Jason.DecodeError{}} =
             RecordRange.decode_prefix(rows, prefix, &Jason.decode/1)
  end

  test "returns an error for a malformed range row" do
    assert {:error, {:invalid_range_row, :invalid}} =
             RecordRange.decode_prefix([:invalid], "steps/", &Jason.decode/1)
  end
end
