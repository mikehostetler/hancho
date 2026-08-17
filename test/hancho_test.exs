defmodule HanchoTest do
  use ExUnit.Case, async: true

  test "uses the Mix project version" do
    assert Hancho.version() == Mix.Project.config()[:version]
  end
end
