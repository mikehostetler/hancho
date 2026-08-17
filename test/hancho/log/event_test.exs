defmodule Hancho.Log.EventTest do
  use ExUnit.Case, async: true

  alias Hancho.Log.Event

  test "normalizes one factory activity event" do
    timestamp = ~U[2026-08-16 12:00:00.000000Z]

    assert {:ok, event} =
             Event.new("hello",
               sequence: 7,
               timestamp: timestamp,
               level: :notice,
               event: "harness.output",
               metadata: [actor: :codex, nested: %{attempt: 2}, pid: self()]
             )

    assert Event.to_map(event) == %{
             "schema_version" => 1,
             "sequence" => 7,
             "timestamp" => "2026-08-16T12:00:00.000000Z",
             "level" => "notice",
             "event" => "harness.output",
             "message" => "hello",
             "message_encoding" => "utf8",
             "metadata" => %{
               "actor" => "codex",
               "nested" => %{"attempt" => 2},
               "pid" => inspect(self())
             }
           }
  end

  test "preserves invalid UTF-8 bytes as base64" do
    assert {:ok, event} = Event.new(<<255, 0, 1>>)
    assert event.message == Base.encode64(<<255, 0, 1>>)
    assert event.message_encoding == :base64

    assert Event.normalize(%{payload: <<255>>}) == %{
             "payload" => %{"data" => Base.encode64(<<255>>), "encoding" => "base64"}
           }
  end

  test "rejects invalid event fields" do
    assert Event.new("message", level: :invalid) == {:error, {:invalid_level, :invalid}}
    assert Event.new("message", event: "") == {:error, {:invalid_event, ""}}
    assert Event.new("message", sequence: -1) == {:error, {:invalid_sequence, -1}}

    assert Event.new("message", metadata: [:not_a_pair]) ==
             {:error, {:invalid_metadata, [:not_a_pair]}}
  end
end
