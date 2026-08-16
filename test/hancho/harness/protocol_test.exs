defmodule Hancho.Harness.ProtocolTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.{Protocol, Request}

  test "round-trips a complete version 1 request" do
    request = request_fixture()
    assert {:ok, decoded} = request |> Protocol.encode_request() |> Protocol.decode_request()
    assert decoded.run_id == request.run_id
    assert decoded.capability == "read"
    assert decoded.protocol_version == 1
  end

  test "rejects an unsupported version and unknown field" do
    data = request_fixture() |> Map.from_struct() |> Map.put(:protocol_version, 99)

    assert {:error, %{code: :unsupported_protocol}} =
             data |> Hancho.JSON.encode!() |> Protocol.decode_request()

    data = request_fixture() |> Map.from_struct() |> Map.put(:new_required_field, true)

    assert {:error, %{code: :unknown_request_fields}} =
             data |> Hancho.JSON.encode!() |> Protocol.decode_request()
  end

  test "parses normalized JSON Lines events and a final result" do
    output = """
    {"type":"event","name":"progress","value":1}
    {"type":"result","status":"success","session_id":"session-1","exit_status":0}
    """

    identity = %{adapter: "fixture", harness: "fixture", stdout_path: "out", stderr_path: "err"}
    assert {:ok, result} = Protocol.parse_output(output, identity)
    assert result.status == "success"
    assert [%{"name" => "progress"}] = Enum.map(result.events, &Map.take(&1, ["name"]))
  end

  test "rejects malformed output and a missing final result" do
    identity = %{adapter: "fixture", harness: "fixture"}
    assert {:error, %{code: :malformed_output}} = Protocol.parse_output("not-json\n", identity)

    assert {:error, %{code: :missing_result}} =
             Protocol.parse_output(~s({"type":"event","name":"only"}\n), identity)
  end

  test "treats a claimed Git effect only as untrusted harness event data" do
    output = """
    {"type":"event","name":"git.push.completed","commit":"untrusted"}
    {"type":"result","status":"success","session_id":"session-1","exit_status":0}
    """

    assert {:ok, result} =
             Protocol.parse_output(output, %{
               adapter: "fixture",
               harness: "fixture",
               stdout_path: "out",
               stderr_path: "err"
             })

    assert [%{"name" => "git.push.completed"}] =
             Enum.map(result.events, &Map.take(&1, ["name"]))

    refute Map.has_key?(Map.from_struct(result), :effect_status)
  end

  defp request_fixture do
    root = temporary_directory!()

    %Request{
      run_id: "run-one",
      workflow: "walking_skeleton",
      workflow_version: 1,
      station: "operate",
      repository_path: root,
      worktree_path: root,
      prompt_path: Path.join(root, "prompt.md"),
      capability: "read",
      authority: "read_only",
      paths: %{
        "request" => Path.join(root, "request.json"),
        "stdout" => Path.join(root, "stdout.log"),
        "stderr" => Path.join(root, "stderr.log")
      }
    }
  end
end
