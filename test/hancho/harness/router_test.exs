defmodule Hancho.Harness.RouterTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.Router
  alias Hancho.{Config, Repository}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    %{repository: repository, config: config}
  end

  test "resolves a compatible station without putting a harness in the workflow", context do
    definition = Hancho.Workflows.Build.V1.definition()
    assert {:ok, resolved} = Router.resolve(context.config, definition, "implement")
    assert resolved.name == "fake"
    assert resolved.module == Hancho.Harness.Fake
    assert resolved.station.capability == "edit_worktree"
  end

  test "rejects a route before the adapter starts when a capability is missing", context do
    definition = Hancho.Workflows.Build.V1.definition()
    config = put_in(context.config, [:data, "harnesses", "fake", "capabilities"], ["read"])

    assert {:error, %{code: :missing_capability}} =
             Router.resolve(config, definition, "implement")
  end

  test "validates every installed station route", context do
    definitions = [
      Hancho.Workflows.WalkingSkeleton.V1.definition(),
      Hancho.Workflows.Build.V1.definition()
    ]

    assert :ok = Router.validate_routes(context.config, definitions)
  end
end
