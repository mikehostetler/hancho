defmodule Hancho.GatesTest do
  use ExUnit.Case, async: true

  alias Hancho.Gates

  test "requires exact dependency and Phoenix migration approvals" do
    assert Enum.sort(
             Gates.required([
               "mix.exs",
               "mix.lock",
               "priv/repo/migrations/20260816000000_add_jobs.exs"
             ])
           ) == ["dependency", "migration"]

    assert Gates.missing(["dependency", "migration"], ["dependency"]) == ["migration"]
  end
end
