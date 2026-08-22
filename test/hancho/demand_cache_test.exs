defmodule Hancho.Demand.CacheTest do
  use ExUnit.Case, async: true

  alias Hancho.Demand.{Cache, Record}

  @tag :tmp_dir
  test "writes an apply-only cache and ordered intent and receipt history", %{tmp_dir: root} do
    project = Hancho.Project.new(root)

    record =
      Record.new!(%{
        kind: "epic",
        title: "Demand",
        github_repository: "owner/repo",
        github_node_id: "node",
        github_number: 1,
        github_url: "https://github.test/owner/repo/issues/1",
        github_status: "open",
        beadwork_id: "bw-1",
        beadwork_status: "open",
        mapping_status: "mapped"
      })

    assert :ok = Cache.intent(project, "owner/repo", ["create mapping"])
    assert :ok = Cache.receipt(project, "owner/repo", [record], ["created bw-1"])

    cache = Cache.cache_path(project) |> File.read!() |> Jason.decode!()
    assert cache["repository"] == "owner/repo"
    assert [%{"github_node_id" => "node", "beadwork_id" => "bw-1"}] = cache["mappings"]

    events =
      Cache.history_path(project)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert Enum.map(events, & &1["event"]) == ["demand.sync.intent", "demand.sync.receipt"]
  end
end
