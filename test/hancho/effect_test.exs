defmodule Hancho.EffectTest do
  use ExUnit.Case, async: false

  alias Hancho.Workflow.{Definition, Effect, Store}

  defmodule ReceiptFailureStore do
    def begin_effect(store, run_id, position, key, kind, intent),
      do: Store.begin_effect(store, run_id, position, key, kind, intent)

    def complete_effect(store, run_id, position, key, receipt) do
      if Process.get(__MODULE__, true) do
        Process.put(__MODULE__, false)
        {:error, :simulated_crash_gap}
      else
        Store.complete_effect(store, run_id, position, key, receipt)
      end
    end

    def fail_effect(store, run_id, position, key, reason),
      do: Store.fail_effect(store, run_id, position, key, reason)
  end

  test "reconciles an external effect after receipt persistence fails" do
    root = temporary_directory()
    project = Hancho.Project.new(root)
    marker = Path.join(root, "external-effect")
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    {:ok, definition} =
      Definition.new(%{
        name: "effect-test",
        version: 1,
        steps: [%{name: "write", action: "Test.Write", params: %{}}]
      })

    yaml = "name: effect-test\nversion: 1\nsteps: []\n"

    source = %{
      path: "effect-test.yaml",
      yaml: yaml,
      sha256: :crypto.hash(:sha256, yaml) |> Base.encode16(case: :lower)
    }

    assert {:ok, store} = Store.open(project.bedrock_path)
    assert :ok = Store.create_run(store, "effect-run", definition, %{}, source)
    assert :ok = Store.start_step(store, "effect-run", 0, hd(definition.steps), %{})

    context = %{
      effect_store: %{
        api: ReceiptFailureStore,
        store: store,
        run_id: "effect-run",
        step_position: 0
      }
    }

    reconcile = fn ->
      if File.exists?(marker), do: {:ok, %{path: marker}}, else: :not_applied
    end

    apply = fn ->
      Agent.update(counter, &(&1 + 1))
      File.write!(marker, "applied")
      {:ok, %{path: marker}}
    end

    assert {:error, {:effect_receipt_failed, :simulated_crash_gap}} =
             Effect.run(context, "write", "file.write", %{path: marker}, reconcile, apply)

    assert {:ok, %{path: ^marker}} =
             Effect.run(context, "write", "file.write", %{path: marker}, reconcile, apply)

    assert Agent.get(counter, & &1) == 1
    Store.flush(store)
  end

  defp temporary_directory do
    path = Path.join(System.tmp_dir!(), "hancho-effect-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    path
  end
end
