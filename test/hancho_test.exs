defmodule HanchoTest do
  use ExUnit.Case, async: true

  test "has a version" do
    assert Hancho.version() == "0.1.0"
  end

  test "encodes stable JSON" do
    assert Hancho.JSON.encode!(%{schema_version: 1, ok: true}) ==
             ~s({"ok":true,"schema_version":1})
  end

  test "round-trips JSON null as nil" do
    assert Hancho.JSON.decode!(~s({"value":null}))["value"] == nil
    assert Hancho.JSON.encode!(%{value: :null}) == ~s({"value":null})
  end
end
