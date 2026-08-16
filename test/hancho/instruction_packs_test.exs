defmodule Hancho.InstructionPacksTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Harness.Router
  alias Hancho.{Config, InstructionPack, InstructionPacks, Repository}

  setup do
    root = temporary_git_repository!("guidance")
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    %{root: root, repository: repository}
  end

  test "configuration replaces station guidance without workflow code changes", context do
    config_path = Repository.config_path(context.repository)

    File.write!(
      config_path,
      File.read!(config_path) <>
        "\n[guidance.plan.research]\npacks = [\"compound_plan\"]\n"
    )

    assert {:ok, config} = Config.load(context.repository)

    assert [%{name: "compound_plan", status: "ready"}] =
             InstructionPacks.resolve(config, "plan", "research")
             |> Enum.map(&Map.take(&1, [:name, :status]))

    assert Enum.all?(InstructionPacks.list(), fn %InstructionPack{} = pack ->
             Map.keys(Map.from_struct(pack)) --
               [
                 :name,
                 :version,
                 :source,
                 :fragment,
                 :required_capabilities,
                 :expected_artifacts,
                 :optional
               ] == []
           end)
  end

  test "keeps design guidance admitted and optional skill setup explicit", context do
    assert {:ok, config} = Config.load(context.repository)
    build = InstructionPacks.resolve(config, "build", "implement", %{design_work: false})
    assert Enum.find(build, &(&1.name == "impeccable")).status == "skipped"

    admitted = InstructionPacks.resolve(config, "build", "implement", %{design_work: true})
    assert Enum.find(admitted, &(&1.name == "impeccable")).status == "ready"

    plan = InstructionPacks.resolve(config, "plan", "research")
    assert Enum.find(plan, &(&1.name == "matt_pocock")).status == "setup_required"

    audit = InstructionPacks.resolve(config, "audit", "inspect")
    canonical = Enum.find(audit, &(&1.name == "canonical_audit"))

    assert canonical.source ==
             "https://gist.github.com/aarondfrancis/8735edbe48532f97ee5ea818db4dbd47"

    refute canonical.pack.fragment =~ "You are"
  end

  test "routes Pi implementation, Codex review, and a separate plan harness by configuration",
       context do
    {:ok, config} = Config.load(context.repository)

    data =
      config.data
      |> put_in(
        ["harnesses", "pi"],
        %{
          "adapter" => "/tmp/pi-hancho-adapter",
          "command" => "pi",
          "capabilities" => ["read", "edit_worktree"]
        }
      )
      |> put_in(
        ["harnesses", "codex"],
        %{
          "adapter" => "builtin:codex",
          "command" => "codex",
          "capabilities" => ["read", "review"]
        }
      )
      |> put_in(["routes", "build", "implement"], "pi")
      |> put_in(["routes", "build", "review"], "codex")
      |> put_in(["routes", "plan", "research"], "codex")

    config = %{config | data: data}

    assert {:ok, %{name: "pi", module: Hancho.Harness.External}} =
             Router.resolve(config, Hancho.Workflows.Build.V1.definition(), "implement")

    assert {:ok, %{name: "codex", module: Hancho.Harness.Codex}} =
             Router.resolve(config, Hancho.Workflows.Build.V1.definition(), "review")

    assert {:ok, %{name: "codex"}} =
             Router.resolve(config, Hancho.Workflows.Plan.V1.definition(), "research")
  end
end
