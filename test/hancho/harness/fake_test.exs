defmodule Hancho.Harness.FakeTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.{Fake, Request}

  test "reports the exact request and emits deterministic slow output without an OS process" do
    root = temporary_directory!("fake-slow-output")
    request = request(root, "run-fake")

    assert {:ok, result} =
             Fake.run(request, %{
               "mode" => "slow_output",
               "chunk_delay_ms" => 1,
               "observer" => self()
             })

    assert_receive {:fake_request, ^request}
    assert result.status == "success"
    assert File.read!(request.paths["stdout"]) == "first chunk\nsecond chunk\n"
    assert File.read!(request.paths["stderr"]) == "slow warning\n"
  end

  test "normalizes success, failure, timeout, malformed output, and cancellation" do
    root = temporary_directory!("fake-modes")
    request = request(root, "run-fake-modes")

    for mode <- ~w(success failure timeout cancelled output_limit) do
      assert {:ok, %{status: ^mode}} = Fake.run(request, %{"mode" => mode})
    end

    assert {:error, %{code: :malformed_adapter_output}} =
             Fake.run(request, %{"mode" => "malformed"})
  end

  defp request(root, run_id) do
    %Request{
      run_id: run_id,
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
