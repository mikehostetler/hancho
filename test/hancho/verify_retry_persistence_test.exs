defmodule Hancho.VerifyRetryPersistenceTest do
  use ExUnit.Case, async: false

  @moduletag :subprocess

  test "allocates a new verification log in a new CLI process" do
    root =
      Path.join(
        System.tmp_dir!(),
        "hancho-verify-retry-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    expression = """
    root = #{inspect(root)}
    params = %{
      repo_path: root,
      worktree_path: root,
      executable: "true",
      arguments: [],
      timeout_ms: 5_000
    }
    {:ok, result} =
      Hancho.Actions.Verify.run(params, %{run_id: "retry-collision", log: :disabled})
    IO.puts("VERIFICATION_LOG=" <> result.output_path)
    """

    assert {first_output, 0} = run_mix(expression)
    assert {second_output, 0} = run_mix(expression)
    first_path = output_path(first_output)
    second_path = output_path(second_output)
    refute first_path == second_path
    assert File.regular?(first_path)
    assert File.regular?(second_path)
  end

  defp run_mix(expression) do
    System.cmd(
      System.find_executable("elixir"),
      ["-S", "mix", "run", "--no-compile", "--no-deps-check", "-e", expression],
      cd: Path.expand("../..", __DIR__),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  defp output_path(output) do
    [path] = Regex.run(~r/VERIFICATION_LOG=(.+)/, output, capture: :all_but_first)
    String.trim(path)
  end
end
