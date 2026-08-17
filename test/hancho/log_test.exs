defmodule Hancho.LogTest do
  use ExUnit.Case, async: false

  alias Hancho.Config
  alias Hancho.Command
  alias Hancho.Log
  alias Hancho.Project

  setup do
    root = Path.join(System.tmp_dir!(), "hancho-log-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    project = Project.new(root)
    {:ok, config} = Config.default(project)
    previous_module_level = Log |> Logger.get_module_level() |> Keyword.get(Log)

    on_exit(fn ->
      _result = :logger.remove_handler(:hancho_factory_file)
      _result = :logger.remove_handler_filter(:default, :hancho_factory_console_filter)
      restore_module_level(previous_module_level)
      File.rm_rf!(root)
    end)

    %{project: project, config: config, previous_module_level: previous_module_level}
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

  test "normalizes binary Hancho internal events", context do
    config =
      configure(context.config,
        console: false,
        include_internal: true,
        sync_interval_ms: 0
      )

    assert {:ok, log} = Log.open(context.project, config)
    assert :ok = Log.internal(:info, <<255, 0>>)
    assert :ok = Log.sync(log)
    assert :ok = Log.close(log)

    [event] = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))
    assert event["message"] == Base.encode64(<<255, 0>>)
    assert event["message_encoding"] == "base64"
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

  test "captures command output through a reusable sink", context do
    config = configure(context.config, console: false, sync_interval_ms: 0)

    assert {:ok, log} = Log.open(context.project, config, metadata: %{run_id: "run-2"})
    sink = Log.output_sink(log, event_prefix: "process", metadata: %{command: "probe"})

    assert {:ok, result} =
             Command.run(
               "/bin/sh",
               ["-c", "printf output; printf error >&2"],
               on_output: sink
             )

    assert result.stdout == "output"
    assert result.stderr == "error"
    assert :ok = Log.close(log)

    events = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))
    assert Enum.map(events, & &1["sequence"]) == [1, 2]

    assert Enum.sort(Enum.map(events, & &1["event"])) == [
             "process.stderr",
             "process.stdout"
           ]

    assert Enum.sort(Enum.map(events, & &1["message"])) == ["error", "output"]

    assert Enum.all?(events, fn event ->
             event["metadata"]["command"] == "probe" and
               event["metadata"]["run_id"] == "run-2" and
               event["metadata"]["stream"] in ["stdout", "stderr"]
           end)
  end

  test "rotates and compresses activity logs", context do
    config =
      configure(context.config,
        console: false,
        sync_interval_ms: 0,
        max_bytes: 300,
        max_files: 2,
        compress: true
      )

    assert {:ok, log} = Log.open(context.project, config)

    for number <- 1..12 do
      assert :ok = Log.write(log, String.duplicate("x", 100), metadata: %{number: number})
    end

    path = Log.path(log)
    assert :ok = Log.close(log)

    assert File.exists?(path)
    assert File.exists?(path <> ".0.gz")
    assert File.exists?(path <> ".1.gz")

    archived_events =
      path
      |> Kernel.<>(".0.gz")
      |> File.read!()
      |> :zlib.gunzip()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert archived_events != []
    assert Enum.all?(archived_events, &(&1["schema_version"] == 1))
  end

  test "writes activity below the primary Logger level", context do
    previous_level = Logger.level()
    on_exit(fn -> Logger.configure(level: previous_level) end)
    :ok = Logger.configure(level: :error)

    config = configure(context.config, console: false, sync_interval_ms: 0)
    assert {:ok, log} = Log.open(context.project, config)
    assert :ok = Log.write(log, "debug detail", level: :debug)
    assert :ok = Log.close(log)

    [event] = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))
    assert event["level"] == "debug"
    assert event["message"] == "debug detail"
    assert Log |> Logger.get_module_level() |> Keyword.get(Log) == context.previous_module_level
  end

  test "keeps the active writer usable when a second writer cannot open", context do
    config = configure(context.config, console: false, sync_interval_ms: 0)

    assert {:ok, log} = Log.open(context.project, config)
    assert {:error, _reason} = Log.open(context.project, config)
    assert :ok = Log.write(log, "still active")
    assert :ok = Log.close(log)

    [event] = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))
    assert event["message"] == "still active"
  end

  test "continues event sequence numbers after the writer reopens", context do
    config = configure(context.config, console: false, sync_interval_ms: 0)

    assert {:ok, first} = Log.open(context.project, config)
    assert :ok = Log.write(first, "before restart")
    assert :ok = Log.close(first)

    assert {:ok, second} = Log.open(context.project, config)
    assert :ok = Log.write(second, "after restart")
    assert :ok = Log.close(second)

    events = read_json_lines(Path.join(context.project.logs_path, "factory.jsonl"))
    assert Enum.map(events, & &1["sequence"]) == [1, 2]
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

  defp restore_module_level(nil), do: Logger.delete_module_level(Log)
  defp restore_module_level(level), do: Logger.put_module_level(Log, level)
end
