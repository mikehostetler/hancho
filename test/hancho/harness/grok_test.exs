defmodule Hancho.Harness.GrokTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.{Grok, Request}

  test "normalizes success and denies harness commit and push authority" do
    root = temporary_directory!("grok")
    arguments = Path.join(root, "arguments")

    command =
      executable!(root, "grok", """
      #!/bin/sh
      if [ "$1" = "--version" ]; then echo 'grok-fixture 1'; exit 0; fi
      printf '%s\n' "$@" > '#{arguments}'
      printf 'ok'
      """)

    request = request(root, 2_000)
    config = %{"command" => command, "permission_mode" => "acceptEdits"}
    assert {:ok, %{status: "pass"}} = Grok.doctor(config)
    assert {:ok, %{harness_version: "grok-fixture 1"}} = Grok.version(config)
    assert {:ok, result} = Grok.run(request, config)
    assert result.status == "success"
    recorded = File.read!(arguments)
    assert recorded =~ "Bash(git commit*)"
    assert recorded =~ "Bash(git push*)"
    assert recorded =~ request.prompt_path
  end

  test "normalizes CLI failure and timeout without a real model", do: run_failure_contracts()

  defp run_failure_contracts do
    root = temporary_directory!("grok-failures")

    failure =
      executable!(
        root,
        "failure",
        "#!/bin/sh\n[ \"$1\" = \"--version\" ] && { echo v1; exit 0; }\nexit 3\n"
      )

    assert {:ok, failed} = Grok.run(request(root, 2_000), %{"command" => failure})
    assert failed.status == "failure"
    assert failed.exit_status == 3

    slow =
      executable!(
        root,
        "slow",
        "#!/bin/sh\n[ \"$1\" = \"--version\" ] && { echo v1; exit 0; }\nsleep 2\n"
      )

    assert {:ok, timeout} = Grok.run(request(root, 50), %{"command" => slow})
    assert timeout.status == "timeout"
  end

  defp request(root, timeout) do
    prompt = Path.join(root, "prompt.md")
    File.write!(prompt, "Read or edit only the admitted worktree.")

    %Request{
      run_id: "run-grok",
      workflow: "build",
      workflow_version: 1,
      station: "implement",
      repository_path: root,
      worktree_path: root,
      prompt_path: prompt,
      capability: "edit_worktree",
      authority: "bounded_edit",
      paths: %{
        "request" => Path.join(root, "request.json"),
        "stdout" => Path.join(root, "stdout-#{timeout}.log"),
        "stderr" => Path.join(root, "stderr-#{timeout}.log")
      },
      limits: %{"timeout_ms" => timeout, "max_output_bytes" => 100_000}
    }
  end

  defp executable!(root, name, content) do
    path = Path.join(root, name)
    File.write!(path, content)
    File.chmod!(path, 0o700)
    path
  end
end
