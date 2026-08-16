defmodule Hancho.Gates do
  @moduledoc false

  @spec required([String.t()], [String.t()]) :: [String.t()]
  def required(paths, configured \\ []) do
    detected =
      []
      |> maybe_add(Enum.any?(paths, &(&1 in ["mix.exs", "mix.lock"])), "dependency")
      |> maybe_add(
        Enum.any?(
          paths,
          &(String.starts_with?(&1, "priv/repo/migrations/") or
              String.starts_with?(&1, "priv/resource_snapshots/"))
        ),
        "migration"
      )

    Enum.uniq(configured ++ detected)
  end

  @spec missing([String.t()], [String.t()]) :: [String.t()]
  def missing(required, approvals), do: required -- approvals

  defp maybe_add(list, true, gate), do: [gate | list]
  defp maybe_add(list, false, _gate), do: list
end
