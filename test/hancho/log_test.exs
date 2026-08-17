defmodule Hancho.LogTest do
  use ExUnit.Case, async: false

  alias Hancho.Config
  alias Hancho.Log
  alias Hancho.Project

  setup do
    root = Path.join(System.tmp_dir!(), "hancho-log-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project = Project.new(root)
    {:ok, config} = Config.default(project)

    on_exit(fn ->
      _result = :logger.remove_handler(:hancho_factory_file)
      _result = :logger.remove_handler_filter(:default, :hancho_factory_console_filter)
      File.rm_rf!(root)
    end)

    %{project: project, config: config}
  end

  test "writes ordered JSON Lines events with normalized metadata", context do
    config = configure(context.config, console: false, sync_interval_ms: 0)

    assert {:ok, log} = Log.open(context.project, config, metadata: %{run_id: "run-1"})
    assert Log.path(log) == Path.join(context.project.logs_path, "factory.jsonl")

    assert :ok =
             Log.write(log, "first\nline",
               event: "command.stdout",
               metadata: %{actor: :codex}
             )

    assert :ok =
             Log.write(log, <<255, 0>>,
               event: "command.stderr",
               level: :warning,
               metadata: %{attempt: 2}
             )

    assert :ok = Log.sync(log)
    assert :ok = Log.close(log)

    [first, second] = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))

    assert first == %{
             "event" => "command.stdout",
             "level" => "info",
             "message" => "first\nline",
             "message_encoding" => "utf8",
             "metadata" => %{"actor" => "codex", "run_id" => "run-1"},
             "schema_version" => 1,
             "sequence" => 1,
             "timestamp" => first["timestamp"]
           }

    assert {:ok, _timestamp, 0} = DateTime.from_iso8601(first["timestamp"])
    assert second["event"] == "command.stderr"
    assert second["level"] == "warning"
    assert second["message"] == Base.encode64(<<255, 0>>)
    assert second["message_encoding"] == "base64"
    assert second["metadata"] == %{"attempt" => 2, "run_id" => "run-1"}
    assert second["sequence"] == 2
  end

  test "writes a one-line text format", context do
    config =
      configure(context.config, format: :text, console: false, sync_interval_ms: 0)

    assert {:ok, log} = Log.open(context.project, config)
    assert :ok = Log.write(log, "one\ntwo", event: "workflow.step", metadata: %{step: 3})
    assert :ok = Log.close(log)

    contents = File.read!(Path.join(context.project.logs_path, "factory.jsonl"))
    assert contents =~ " INFO workflow.step one\\ntwo "
    assert contents =~ ~S("step":3)
    assert length(String.split(contents, "\n", trim: true)) == 1
  end

  test "can include Hancho internal Logger events", context do
    config =
      configure(context.config,
        console: false,
        include_internal: true,
        sync_interval_ms: 0
      )

    assert {:ok, log} = Log.open(context.project, config)
    assert :ok = Log.internal(:notice, "runtime ready", component: :scheduler)
    assert :ok = Log.sync(log)
    assert :ok = Log.close(log)

    [event] = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))
    assert event["event"] == "hancho.internal"
    assert event["level"] == "notice"
    assert event["message"] == "runtime ready"
    assert event["metadata"]["component"] == "scheduler"
  end

  test "does not create a log when activity logging is disabled", context do
    config = configure(context.config, enabled: false)

    assert {:ok, :disabled} = Log.open(context.project, config)
    assert :ok = Log.write(:disabled, "ignored")
    assert :ok = Log.sync(:disabled)
    assert Log.path(:disabled) == nil
    assert :ok = Log.close(:disabled)
    refute File.exists?(context.project.logs_path)
  end

  test "rejects bad metadata without advancing the event sequence", context do
    config = configure(context.config, console: false, sync_interval_ms: 0)

    assert {:ok, log} = Log.open(context.project, config)

    assert {:error, {:invalid_metadata, ["not a keyword"]}} =
             Log.write(log, "bad", metadata: ["not a keyword"])

    assert :ok = Log.write(log, "good")
    assert :ok = Log.close(log)

    [event] = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))
    assert event["sequence"] == 1
    assert event["message"] == "good"
  end

  defp configure(config, options) do
    logs =
      Enum.reduce(options, config.logs, fn {key, value}, logs -> Map.put(logs, key, value) end)

    %{config | logs: logs}
  end

  defp read_json_lines(path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
