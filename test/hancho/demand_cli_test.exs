defmodule Hancho.DemandCLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  defmodule ProjectAPI do
    def discover(cwd: cwd), do: {:ok, Hancho.Project.new(cwd)}
  end

  defmodule Demands do
    def list(_project, "all", _options) do
      {:ok,
       %{
         repository: "owner/repo",
         source: "all",
         records: [
           %{
             mapping_status: "unmapped",
             kind: "task",
             github_number: nil,
             beadwork_id: "bw-local",
             title: "Local work"
           }
         ]
       }}
    end

    def audit(_project, _options),
      do: {:ok, %{repository: "owner/repo", findings: [], records: []}}

    def sync(_project, mode, _options) do
      send(self(), {:sync_mode, mode})
      {:ok, %{mode: mode, actions: ["create mapping"], records: []}}
    end
  end

  @options [cwd: "/repo", project_api: ProjectAPI, demands_api: Demands]

  test "prints the combined demand view" do
    output = capture_io(fn -> assert Hancho.CLI.run(["demands", "list"], @options) == 0 end)
    assert output =~ "Outstanding demands for owner/repo"
    assert output =~ "unmapped task no GitHub Issue <-> bw-local"
  end

  test "keeps audit read-only and reports a clean mapping" do
    output = capture_io(fn -> assert Hancho.CLI.run(["demands", "audit"], @options) == 0 end)
    assert output =~ "No mapping findings."
  end

  test "requires one explicit sync mode" do
    output =
      capture_io(:stderr, fn ->
        assert Hancho.CLI.run(["demands", "sync"], @options) == 2
      end)

    assert output =~ "requires exactly one"

    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["demands", "sync", "--dry-run"], @options) == 0
      end)

    assert output =~ "Dry run: 1 demand mapping actions."
    assert_received {:sync_mode, :dry_run}
  end
end
