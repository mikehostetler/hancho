defmodule Hancho.HarnessTest do
  use ExUnit.Case, async: false

  test "starts Jido.Harness through the shared command runtime" do
    assert Hancho.Harness.ensure_started() == :ok
    assert is_binary(Jido.Harness.version())
    assert Jido.Harness.providers() != []
  end

  test "reports detached run identity and normalized progress" do
    providers = Application.get_env(:jido_harness, :providers)
    directory = temporary_directory()
    :ok = Hancho.Harness.ensure_started()

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, Hancho.TestHarnessAdapter)
    )

    on_exit(fn ->
      if providers do
        Application.put_env(:jido_harness, :providers, providers)
      else
        Application.delete_env(:jido_harness, :providers)
      end
    end)

    test_pid = self()

    assert {:ok, result} =
             Hancho.Harness.run_with_progress(
               :codex,
               "Implement Beadwork task hancho-integration",
               [
                 cwd: directory,
                 approval_mode: :auto_edit,
                 sandbox_mode: :workspace_write,
                 await_timeout: 1_000,
                 progress_interval_ms: 5
               ],
               fn progress ->
                 send(test_pid, {:progress, progress})
                 :ok
               end
             )

    assert_received {:progress, %{phase: :started, harness_run_id: run_id}}

    assert_received {:progress,
                     %{
                       phase: :completed,
                       harness_run_id: ^run_id,
                       last_event: :run_completed
                     }}

    assert result.run_id == run_id
    assert result.status == :completed
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
