defmodule Hancho.StateCorruptionTest do
  use ExUnit.Case, async: false

  alias Hancho.State.{Bedrock, Repo}
  alias Hancho.Workflow.{RunRecord, Store}

  test "reports a corrupt durable run as an invalid state record" do
    root = temporary_directory()
    project = Hancho.Project.new(root)
    run_id = "corrupt-run"
    key = "hancho/workflow/runs/#{Base.url_encode64(run_id, padding: false)}/run"

    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Bedrock.transaction(store, fn ->
               Repo.put(key, "{not-json")
             end)

    assert {:error, {:invalid_state_record, RunRecord, {:invalid_state, _message}}} =
             Store.fetch_run(store, run_id)

    Store.flush(store)
  end

  test "rejects a durable record from an unknown schema version" do
    root = temporary_directory()
    project = Hancho.Project.new(root)
    run_id = "future-run"
    key = "hancho/workflow/runs/#{Base.url_encode64(run_id, padding: false)}/run"

    record = %{
      "record_version" => 2,
      "transition_version" => 0,
      "id" => run_id,
      "workflow_name" => "implement",
      "workflow_version" => 1,
      "workflow_source_path" => "implement.yaml",
      "workflow_yaml" => "name: implement",
      "workflow_sha256" => "abc",
      "status" => "running",
      "current_step" => nil,
      "input_json" => "{}",
      "started_at" => "2026-08-17T00:00:00Z",
      "finished_at" => nil,
      "error_json" => nil
    }

    assert {:ok, store} = Store.open(project.bedrock_path)

    assert :ok =
             Bedrock.transaction(store, fn ->
               Repo.put(key, Jason.encode!(record))
             end)

    assert {:error, {:invalid_state_record, RunRecord, _reason}} =
             Store.fetch_run(store, run_id)

    Store.flush(store)
  end

  defp temporary_directory do
    path =
      Path.join(System.tmp_dir!(), "hancho-corruption-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)

    on_exit(fn ->
      Hancho.State.Bedrock.reset()
      File.rm_rf!(path)
    end)

    path
  end
end
