defmodule Hancho.ArtifactsTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Artifacts, Config, Journal, Repository, SQLite, Store}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "artifact-work")
    %{repository: repository, run_id: work_order["id"]}
  end

  test "stores file evidence and validates its hash", context do
    assert {:ok, artifact} =
             Artifacts.write(
               context.repository,
               context.run_id,
               "log",
               "harness.log",
               "large output",
               media_type: "text/plain",
               retention: "diagnostic"
             )

    assert artifact["byte_size"] == 12
    assert artifact["media_type"] == "text/plain"
    assert :ok = Artifacts.validate(context.repository, artifact)

    path = Path.join(context.repository.runtime_dir, artifact["relative_path"])
    File.write!(path, "changed")
    assert {:error, %{code: :artifact_changed}} = Artifacts.validate(context.repository, artifact)

    assert {:ok, nil} =
             SQLite.scalar(
               Store.path(context.repository),
               "SELECT 1 FROM artifacts WHERE instr(relative_path, 'large output') > 0;"
             )
  end

  test "rejects a path that escapes the run folder", context do
    assert {:error, %{code: :artifact_path_escape}} =
             Artifacts.write(
               context.repository,
               context.run_id,
               "log",
               "../../../outside.log",
               "no"
             )
  end

  test "reports a missing artifact", context do
    {:ok, artifact} =
      Artifacts.write(context.repository, context.run_id, "report", "audit.md", "report")

    path = Path.join(context.repository.runtime_dir, artifact["relative_path"])
    File.rm!(path)
    assert {:error, %{code: :artifact_missing}} = Artifacts.validate(context.repository, artifact)
  end
end
