defmodule Hancho.Harness.ExternalTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.{External, Request}

  test "runs a custom executable through the versioned protocol" do
    root = temporary_directory!()
    adapter = adapter_fixture!(root)
    request = request_fixture(root)
    config = %{"adapter" => adapter, "command" => "fixture", "repository_path" => root}

    assert {:ok, %{"status" => "pass"}} = External.doctor(config)
    assert {:ok, %{"adapter_version" => "1"}} = External.version(config)
    assert {:ok, result} = External.run(request, config)
    assert result.status == "success"
    assert result.adapter == adapter
    assert File.exists?(request.paths["request"])
    assert File.read!(request.paths["stderr"]) == "fixture warning\n"
  end

  test "reports malformed and missing adapter results" do
    root = temporary_directory!()
    request = request_fixture(root)

    malformed =
      executable!(
        root,
        "malformed",
        "#!/bin/sh\n[ \"$1\" = run ] && printf 'bad\\n' || printf '{}\\n'\n"
      )

    config = %{"adapter" => malformed, "command" => "fixture", "repository_path" => root}
    assert {:error, %{code: :malformed_output}} = External.run(request, config)

    missing =
      executable!(
        root,
        "missing",
        "#!/bin/sh\n[ \"$1\" = run ] && printf '{\"type\":\"event\"}\\n' || printf '{}\\n'\n"
      )

    config = %{"adapter" => missing, "command" => "fixture", "repository_path" => root}
    assert {:error, %{code: :missing_result}} = External.run(request, config)
  end

  test "rejects a relative adapter path that escapes local harness configuration" do
    root = temporary_directory!()
    request = request_fixture(root)

    assert {:error, %{code: :adapter_path_escape}} =
             External.run(request, %{
               "adapter" => "../outside-adapter",
               "command" => "fixture",
               "repository_path" => root
             })
  end

  defp adapter_fixture!(root) do
    executable!(
      root,
      "adapter",
      """
      #!/bin/sh
      case "$1" in
        doctor) printf '{"status":"pass"}\n' ;;
        version) printf '{"adapter_version":"1","harness_version":"fixture-1"}\n' ;;
        run)
          test -s "$2" || exit 2
          printf 'fixture warning\n' >&2
          printf '{"type":"event","name":"fixture.progress"}\n'
          printf '{"type":"result","status":"success","session_id":"fixture-session","exit_status":0}\n'
          ;;
        *) exit 64 ;;
      esac
      """
    )
  end

  defp request_fixture(root) do
    prompt = Path.join(root, "prompt.md")
    File.write!(prompt, "Read only")

    %Request{
      run_id: "run-one",
      workflow: "walking_skeleton",
      workflow_version: 1,
      station: "operate",
      repository_path: root,
      worktree_path: root,
      prompt_path: prompt,
      capability: "read",
      authority: "read_only",
      paths: %{
        "request" => Path.join(root, "request.json"),
        "stdout" => Path.join(root, "stdout.log"),
        "stderr" => Path.join(root, "stderr.log")
      },
      limits: %{"timeout_ms" => 2_000, "max_output_bytes" => 100_000}
    }
  end

  defp executable!(root, name, content) do
    path = Path.join(root, name)
    File.write!(path, content)
    File.chmod!(path, 0o700)
    path
  end
end
