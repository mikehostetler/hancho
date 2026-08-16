defmodule Hancho.Harness.CodexTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.{Codex, Request}

  test "passes the common adapter contract with capability-specific sandbox arguments" do
    root = temporary_directory!("codex-adapter")
    executable = Path.join(root, "codex-fixture")
    arguments = Path.join(root, "arguments.txt")

    File.write!(
      executable,
      """
      #!/bin/sh
      if [ "$1" = "--version" ]; then
        echo "codex-fixture 1.2.3"
        exit 0
      fi
      printf '%s\n' "$@" > "#{arguments}"
      echo "completed"
      """
    )

    File.chmod!(executable, 0o700)
    prompt = Path.join(root, "prompt.md")
    File.write!(prompt, "Review exact candidate; $(touch should-not-run)")

    request = %Request{
      run_id: "run-1",
      workflow: "build",
      workflow_version: 1,
      station: "review",
      repository_path: root,
      worktree_path: root,
      prompt_path: prompt,
      capability: "review",
      authority: "read_only",
      paths: %{
        "request" => Path.join(root, "request.json"),
        "stdout" => Path.join(root, "stdout.log"),
        "stderr" => Path.join(root, "stderr.log")
      },
      limits: %{"timeout_ms" => 5_000, "max_output_bytes" => 10_000}
    }

    config = %{"command" => executable, "repository_path" => root}
    assert {:ok, %{status: "pass"}} = Codex.doctor(config)

    assert {:ok, %{adapter_version: "1", harness_version: "codex-fixture 1.2.3"}} =
             Codex.version(config)

    assert {:ok, result} = Codex.run(request, config)
    assert result.status == "success"
    assert result.adapter == "builtin:codex"

    recorded = File.read!(arguments)
    assert recorded =~ "read-only"
    assert recorded =~ "$(touch should-not-run)"
    refute File.exists?(Path.join(root, "should-not-run"))
  end
end
