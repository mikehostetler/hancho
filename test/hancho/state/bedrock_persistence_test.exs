defmodule Hancho.State.BedrockPersistenceTest do
  use ExUnit.Case, async: false

  test "reads flushed state in a new operating-system process" do
    path =
      Path.join(
        System.tmp_dir!(),
        "hancho-bedrock-persistence-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(path) end)

    write = """
    path = #{inspect(path)}
    :ok = Hancho.State.Bedrock.open(path)
    :ok = Hancho.State.Bedrock.transaction(path, fn ->
      Hancho.State.Repo.put("persistence-check", "persisted")
    end)
    :ok = Hancho.State.Bedrock.flush(path)
    """

    read = """
    path = #{inspect(path)}
    :ok = Hancho.State.Bedrock.open(path)
    {:ok, "persisted"} = Hancho.State.Bedrock.transaction(path, fn ->
      {:ok, Hancho.State.Repo.get("persistence-check")}
    end)
    IO.puts("PERSISTED")
    """

    assert {_, 0} = run_mix(write)
    assert {output, 0} = run_mix(read)
    assert output =~ "PERSISTED"
  end

  defp run_mix(expression) do
    System.cmd(
      System.find_executable("elixir"),
      ["-S", "mix", "run", "-e", expression],
      cd: Path.expand("../../..", __DIR__),
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
