defmodule Hancho.HarnessTest do
  use ExUnit.Case, async: false

  alias Jido.Harness.{AdapterSpec, Capabilities, ProviderStatus}

  defmodule SlowAdapter do
    @behaviour Jido.Harness.Adapter

    @impl true
    def spec do
      %AdapterSpec{
        provider: :codex,
        name: "Hancho slow test adapter",
        executable: "hancho-slow-test-adapter",
        capabilities: %Capabilities{},
        normalized_options: [],
        provider_options: []
      }
    end

    @impl true
    def status(_config) do
      {:ok,
       %ProviderStatus{
         provider: :codex,
         installed: true,
         compatible: true,
         authenticated: true,
         smoke_ready: true,
         capabilities: spec().capabilities,
         executable: spec().executable
       }}
    end

    @impl true
    def run(_request, context) do
      send(context.config.test_pid, {:slow_adapter_started, context.run_id})
      Process.sleep(30_000)
      {:ok, []}
    end

    @impl true
    def cancel(run_id, context) do
      send(context.config.test_pid, {:slow_adapter_cancelled, run_id})
      :ok
    end
  end

  test "starts Jido.Harness through the shared command runtime" do
    assert Hancho.Harness.ensure_started() == :ok
    assert is_binary(Jido.Harness.version())
    assert Jido.Harness.providers() != []
  end

  test "reports detached run identity and normalized progress" do
    providers = Application.get_env(:jido_harness, :providers)
    provider_config = Application.get_env(:jido_harness, :provider_config)
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

      if provider_config do
        Application.put_env(:jido_harness, :provider_config, provider_config)
      else
        Application.delete_env(:jido_harness, :provider_config)
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
                 progress_interval_ms: 5,
                 journal_dir: Path.join(directory, "journals")
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

    assert {:ok, info} = Jido.Harness.Run.info(run_id)
    assert String.starts_with?(info.journal_dir, Path.join(directory, "journals"))

    assert {:ok, attached} =
             Hancho.Harness.run_with_progress(
               :codex,
               "This prompt is not used for a retained completed run.",
               [
                 cwd: directory,
                 resume_run_id: run_id,
                 await_timeout: 1_000,
                 progress_interval_ms: 5
               ],
               fn progress ->
                 send(test_pid, {:reattach_progress, progress})
                 :ok
               end
             )

    assert attached.run_id == run_id
    assert_received {:reattach_progress, %{phase: :reattached, reattached: true}}
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  test "cancels a detached run when the Hancho wait boundary expires" do
    providers = Application.get_env(:jido_harness, :providers)
    provider_config = Application.get_env(:jido_harness, :provider_config)
    :ok = Hancho.Harness.ensure_started()

    Application.put_env(
      :jido_harness,
      :providers,
      Map.put(Map.new(providers || %{}), :codex, SlowAdapter)
    )

    Application.put_env(
      :jido_harness,
      :provider_config,
      Map.put(Map.new(provider_config || %{}), :codex, %{test_pid: self()})
    )

    on_exit(fn ->
      restore_env(:providers, providers)
      restore_env(:provider_config, provider_config)
    end)

    assert {:error, {:harness_await_timeout, run_id, :ok, {:ok, %{status: :cancelled}}}} =
             Hancho.Harness.run_with_progress(
               :codex,
               "Wait until Hancho cancels this run.",
               [
                 cwd: temporary_directory(),
                 await_timeout: 25,
                 progress_interval_ms: 5,
                 cancellation_timeout_ms: 1_000
               ],
               fn _progress -> :ok end
             )

    assert_received {:slow_adapter_started, ^run_id}
    assert_received {:slow_adapter_cancelled, ^run_id}
    assert {:ok, %{state: :cancelled}} = Jido.Harness.Run.info(run_id)
    assert :ok = Jido.Harness.Run.prune(run_id)
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-harness-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp restore_env(key, nil), do: Application.delete_env(:jido_harness, key)
  defp restore_env(key, value), do: Application.put_env(:jido_harness, key, value)
end
