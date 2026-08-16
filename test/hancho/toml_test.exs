defmodule Hancho.TOMLTest do
  use ExUnit.Case, async: true

  alias Hancho.TOML

  test "parses strings, numbers, booleans, arrays, tables, and comments" do
    text = """
    schema_version = 1
    enabled = true
    names = ["read", "review"] # comment
    [harnesses.fake]
    command = "fake"
    """

    assert {:ok, data} = TOML.parse(text)
    assert data["schema_version"] == 1
    assert data["enabled"]
    assert data["names"] == ["read", "review"]
    assert data["harnesses"]["fake"]["command"] == "fake"
  end

  test "reports a duplicate key with its line" do
    assert {:error, error} = TOML.parse("value = 1\nvalue = 2\n")
    assert error.message =~ "line 2"
    assert error.message =~ "Duplicate"
  end

  test "accepts standard TOML strings, floats, dates, and inline tables" do
    text = """
    title = 'Hancho'
    ratio = 1.5
    day = 2026-08-16
    limits = { timeout = 10, enabled = true }
    """

    assert {:ok, data} = TOML.parse(text)
    assert data["title"] == "Hancho"
    assert data["ratio"] == 1.5
    assert data["day"] == ~D[2026-08-16]
    assert data["limits"] == %{"timeout" => 10, "enabled" => true}
  end
end
