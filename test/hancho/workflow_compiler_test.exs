defmodule Hancho.WorkflowCompilerTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{Compiler, Definition, Loader, Runner}

  defmodule ReadyHarness do
    def status(provider) do
      Jido.Harness.ProviderStatus.new(%{
        provider: provider,
        installed: true,
        compatible: true,
        authenticated: true,
        smoke_ready: true
      })
    end
  end

  test "compiles the full workflow and its local dependencies" do
    project = project()
    assert :ok = Hancho.Workflow.Default.install(project)
    assert {:ok, definition} = Loader.load(project, "implement")

    assert {:ok, compiled} =
             Compiler.compile(
               project,
               definition,
               %{"repo_path" => project.root, "issue_id" => "hancho-123"},
               services: %{harness: ReadyHarness}
             )

    assert compiled.provider == "codex"
    assert length(compiled.steps) == 11
    assert Enum.any?(compiled.executables, &String.ends_with?(&1, "/mix"))
    assert compiled.prompt_files == ["implement.md"]
  end

  test "rejects action parameter and input errors before state starts" do
    project = project()
    File.mkdir_p!(project.workflows_path)

    workflow = """
    name: invalid
    version: 1
    steps:
      - name: preflight
        action: Hancho.Actions.Preflight
        params:
          repo_path: "$input.missing"
          typo: value
    """

    File.write!(Path.join(project.workflows_path, "invalid.yaml"), workflow)

    assert {:error,
            {:workflow_compile_failed, "preflight", {:missing_input_reference, "$input.missing"}}} =
             Runner.run(project, "invalid", %{"repo_path" => project.root}, log: :disabled)

    refute File.exists?(project.bedrock_path)
  end

  test "rejects unknown providers and missing prompt files" do
    project = project()

    {:ok, provider_workflow} =
      Definition.new(%{
        name: "bad-provider",
        version: 1,
        steps: [
          %{
            name: "implement",
            action: "Hancho.Actions.Implement",
            params: %{
              prompt: "Do the work.",
              worktree_path: project.root,
              provider: "unknown",
              timeout_ms: 1_000
            }
          }
        ]
      })

    assert {:error, {:workflow_compile_failed, "implement", message}} =
             Compiler.compile(project, provider_workflow, %{})

    assert message =~ "Unknown Jido.Harness provider"

    {:ok, prompt_workflow} =
      Definition.new(%{
        name: "bad-prompt",
        version: 1,
        steps: [
          %{
            name: "prompt",
            action: "Hancho.Actions.RenderPrompt",
            params: %{
              repo_path: project.root,
              prompt_file: "missing.md",
              context: %{}
            }
          }
        ]
      })

    assert {:error, {:workflow_compile_failed, "prompt", {:prompt_file_not_found, "missing.md"}}} =
             Compiler.compile(project, prompt_workflow, %{})
  end

  defp project do
    path = Path.join(System.tmp_dir!(), "hancho-compiler-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    Hancho.Project.new(path)
  end
end
