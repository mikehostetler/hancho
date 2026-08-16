defmodule Hancho.CLITest do
  use Hancho.RepositoryCase, async: true

  import ExUnit.CaptureIO

  test "shows help" do
    output = capture_io(fn -> assert Hancho.CLI.run(["help"]) == 0 end)
    assert output =~ "Hancho coordinates"
  end

  test "documents every public command in the router contract" do
    help = Hancho.CLI.Commands.Help.execute([], []).data.help

    assert Hancho.CLI.Router.public_commands() ==
             ~w(approve attach cancel cleanup close config continue decisions deliver doctor down guidance harness help init kaizen logs measures merge pause pr publish queue reconcile reject resume run runs show status up version work workflow)

    Enum.each(Hancho.CLI.Router.public_commands(), fn command ->
      assert help =~ command, "Help does not document public command '#{command}'."
    end)
  end

  test "shows a version as JSON" do
    output = capture_io(fn -> assert Hancho.CLI.run(["version", "--json"]) == 0 end)
    assert %{"schema_version" => 1, "version" => "0.1.0"} = Hancho.JSON.decode!(output)
  end

  test "raises a typed error for an unknown command" do
    assert_raise Hancho.Error, ~r/Unknown command/, fn -> Hancho.CLI.run(["unknown"]) end
  end

  test "initializes a repository through a command module" do
    root = temporary_git_repository!()

    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["init", "--repo", root]) == 0
      end)

    assert output =~ "Initialized Hancho"
    assert File.exists?(Path.join(root, ".hancho/hancho.sqlite3"))
  end

  test "lists workflows as JSON" do
    output = capture_io(fn -> assert Hancho.CLI.run(["workflow", "list", "--json"]) == 0 end)
    data = Hancho.JSON.decode!(output)
    assert Enum.any?(data["workflows"], &(&1["name"] == "build" and &1["version"] == 1))
  end

  test "validates a workflow and every configured station route" do
    root = temporary_git_repository!("workflow-routes")
    capture_io(fn -> assert Hancho.CLI.run(["init", "--repo", root]) == 0 end)

    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["workflow", "validate", "build", "--repo", root]) == 0
      end)

    assert output =~ "harness routes are valid"

    config_path = Path.join(root, ".hancho/config.toml")

    changed =
      config_path
      |> File.read!()
      |> String.replace(
        "[routes.build]\nimplement = \"fake\"\nrepair = \"fake\"\nreview = \"fake\"",
        "[routes.build]\nimplement = \"fake\"\nrepair = \"fake\""
      )

    File.write!(config_path, changed)

    assert_raise Hancho.Error, ~r/build.review.*no harness route/, fn ->
      Hancho.CLI.run(["workflow", "validate", "build", "--repo", root])
    end
  end

  test "lists and checks configured harnesses" do
    root = temporary_git_repository!()
    capture_io(fn -> assert Hancho.CLI.run(["init", "--repo", root]) == 0 end)

    output =
      capture_io(fn ->
        assert Hancho.CLI.run(["harness", "doctor", "fake", "--repo", root, "--json"]) == 0
      end)

    assert %{"result" => "ok", "harnesses" => [%{"name" => "fake", "status" => "pass"}]} =
             Hancho.JSON.decode!(output)
  end

  test "runs and inspects a durable walking-skeleton work order" do
    root = temporary_git_repository!()
    capture_io(fn -> assert Hancho.CLI.run(["init", "--repo", root]) == 0 end)

    run_output =
      capture_io(fn ->
        assert Hancho.CLI.run(["run", "walking_skeleton", "work-cli", "--repo", root, "--json"]) ==
                 0
      end)

    run = Hancho.JSON.decode!(run_output)
    assert run["result"] == "complete"
    run_id = run["work_order"]["id"]

    show_output =
      capture_io(fn ->
        assert Hancho.CLI.run(["show", run_id, "--repo", root, "--json"]) == 0
      end)

    shown = Hancho.JSON.decode!(show_output)
    assert shown["work_order"]["state"] == "complete"
    assert length(shown["events"]) == 6

    logs_output =
      capture_io(fn ->
        assert Hancho.CLI.run(["logs", "--run", run_id, "--repo", root, "--json"]) == 0
      end)

    assert length(Hancho.JSON.decode!(logs_output)["events"]) == 6

    station_output =
      capture_io(fn ->
        assert Hancho.CLI.run([
                 "logs",
                 "--run",
                 run_id,
                 "--station",
                 "operate",
                 "--since",
                 "1h",
                 "--repo",
                 root,
                 "--json"
               ]) == 0
      end)

    assert Enum.all?(Hancho.JSON.decode!(station_output)["events"], fn event ->
             event["event"] in [
               "start",
               "guidance_resolved",
               "harness_started",
               "harness_completed"
             ]
           end)

    raw_output =
      capture_io(fn ->
        assert Hancho.CLI.run([
                 "logs",
                 "--run",
                 run_id,
                 "--raw",
                 "--repo",
                 root,
                 "--json"
               ]) == 0
      end)

    assert Hancho.JSON.decode!(raw_output)["sensitive_warning"] =~ "sensitive"

    {:ok, reopened} = Hancho.Repository.discover(root)

    assert {:ok, _} =
             Hancho.Journal.record_event(reopened, run_id, "andon", reason: "Manual proof stop")

    status_output =
      capture_io(fn -> assert Hancho.CLI.run(["status", "--repo", root, "--json"]) == 0 end)

    assert [%{"event" => "andon", "reason" => "Manual proof stop"}] =
             Hancho.JSON.decode!(status_output)["andon"]
  end
end
