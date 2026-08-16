defmodule Hancho.VerificationTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Config, Journal, Repository, Verification}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "verify-work")
    %{root: root, repository: repository, run_id: work_order["id"]}
  end

  test "records commands, times, output, and stops at a required failure", context do
    commands = [
      ["sh", "-c", "printf pass"],
      ["sh", "-c", "printf fail >&2; exit 9"],
      ["sh", "-c", "exit 0"]
    ]

    assert {:ok, result} =
             Verification.run(context.repository, context.run_id, context.root, commands)

    refute result.passed
    assert length(result.checks) == 2
    assert Enum.at(result.checks, 0).status == "passed"
    assert Enum.at(result.checks, 1).exit_status == 9
    assert Enum.all?(result.checks, &(&1.started_at <= &1.finished_at))
  end

  test "supplies library and Phoenix base profiles" do
    assert [format | _] = Verification.commands("elixir_library", [])
    assert format == ["mix", "format", "--check-formatted"]
    assert Verification.commands("phoenix_private", []) != []
    assert Verification.commands("custom", [["true"]]) == [["true"]]
  end
end
