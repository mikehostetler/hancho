defmodule Hancho.InstructionPacks do
  @moduledoc "Resolves and records reusable guidance without changing workflow policy."

  alias Hancho.InstructionPack
  alias Hancho.{Clock, ID, Repository, SQLite, Store}

  @compound_source "https://github.com/EveryInc/compound-engineering-plugin"
  @impeccable_source "https://github.com/pbakaus/impeccable"
  @audit_source "https://gist.github.com/aarondfrancis/8735edbe48532f97ee5ea818db4dbd47"
  @matt_source "https://github.com/mattpocock/skills"

  @default_mappings %{
    {"plan", "research"} => ["compound_brainstorm", "matt_pocock"],
    {"plan", "draft"} => ["compound_plan"],
    {"plan", "review"} => ["compound_code_review"],
    {"build", "implement"} => ["compound_work", "impeccable"],
    {"build", "repair"} => ["compound_simplify"],
    {"build", "review"} => ["compound_code_review", "compound_compound"],
    {"audit", "inventory"} => ["canonical_audit"],
    {"audit", "inspect"} => ["canonical_audit"],
    {"audit", "validate"} => ["canonical_audit", "compound_code_review"]
  }

  @spec list() :: [InstructionPack.t()]
  def list do
    [
      compound(
        "compound_brainstorm",
        "ce-brainstorm",
        "Clarify the goal, constraints, alternatives, and open decisions before planning."
      ),
      compound(
        "compound_plan",
        "ce-plan",
        "Write bounded tasks, dependencies, risks, checks, and acceptance conditions."
      ),
      compound(
        "compound_work",
        "ce-work",
        "Implement the admitted plan in small verified steps."
      ),
      compound(
        "compound_simplify",
        "ce-simplify-code",
        "Remove avoidable complexity without changing required behavior."
      ),
      compound(
        "compound_code_review",
        "ce-code-review",
        "Review correctness, scope, evidence, risks, and maintainability independently."
      ),
      compound(
        "compound_compound",
        "ce-compound",
        "Capture useful learning as a proposed standard-work improvement."
      ),
      %InstructionPack{
        name: "impeccable",
        version: 1,
        source: @impeccable_source,
        fragment:
          "For admitted design work, use Impeccable guidance to check visual hierarchy, interaction, accessibility, and finish.",
        required_capabilities: ["edit_worktree"],
        expected_artifacts: ["worktree_diff"],
        optional: true
      },
      %InstructionPack{
        name: "canonical_audit",
        version: 1,
        source: @audit_source,
        fragment:
          "Use the canonical Aaron Francis audit source. Keep units bounded and non-overlapping. Retain only material findings with evidence. Do not copy or replace the canonical prompt.",
        required_capabilities: ["read"],
        expected_artifacts: ["audit_report"]
      },
      %InstructionPack{
        name: "matt_pocock",
        version: 1,
        source: @matt_source,
        fragment:
          "Use only explicitly selected, locally installed Matt Pocock skills that match this station.",
        required_capabilities: ["read"],
        expected_artifacts: [],
        optional: true
      }
    ]
  end

  @spec resolve(map(), String.t(), String.t(), map()) :: [map()]
  def resolve(config, workflow, station, context \\ %{}) do
    configured = get_in(config.data, ["guidance", workflow, station, "packs"])

    names =
      if is_list(configured),
        do: configured,
        else: Map.get(@default_mappings, {workflow, station}, [])

    names
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case Enum.find(list(), &(&1.name == name)) do
        nil -> [%{name: name, status: "missing", reason: "Instruction pack is not installed."}]
        pack -> [resolve_pack(pack, config, context)]
      end
    end)
  end

  @spec record(Repository.t(), String.t(), String.t(), [map()]) :: :ok | {:error, term()}
  def record(repository, run_id, station, resolved) do
    Enum.reduce_while(resolved, :ok, fn item, :ok ->
      case item[:pack] do
        %InstructionPack{} = pack ->
          sql = """
          INSERT OR IGNORE INTO instruction_pack_uses
            (id, run_id, station, name, version, source, content_hash, status, recorded_at)
          VALUES
            (#{q(ID.generate("pack"))}, #{q(run_id)}, #{q(station)}, #{q(pack.name)}, #{q(pack.version)},
             #{q(pack.source)}, #{q(InstructionPack.hash(pack))}, #{q(item.status)}, #{q(Clock.utc_now())});
          """

          case SQLite.execute(Store.path(repository), sql) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end

        nil ->
          {:cont, :ok}
      end
    end)
  end

  def uses(repository, run_id) do
    SQLite.query(
      Store.path(repository),
      "SELECT * FROM instruction_pack_uses WHERE run_id = #{q(run_id)} ORDER BY station, name, version;"
    )
  end

  def prompt_fragment(resolved) do
    resolved
    |> Enum.filter(&(&1.status == "ready"))
    |> Enum.map_join("\n\n", fn %{pack: pack} ->
      "Instruction pack #{pack.name}.v#{pack.version}\nSource: #{pack.source}\n#{pack.fragment}"
    end)
  end

  defp resolve_pack(%{name: "impeccable"} = pack, _config, context) do
    if context[:design_work] == true do
      %{
        pack: pack,
        name: pack.name,
        version: pack.version,
        source: pack.source,
        hash: InstructionPack.hash(pack),
        status: "ready"
      }
    else
      %{
        pack: pack,
        name: pack.name,
        version: pack.version,
        source: pack.source,
        hash: InstructionPack.hash(pack),
        status: "skipped",
        reason: "Work was not admitted as design work."
      }
    end
  end

  defp resolve_pack(%{name: "matt_pocock"} = pack, config, _context) do
    if get_in(config.data, ["instruction_packs", "matt_pocock", "installed"]) == true do
      %{
        pack: pack,
        name: pack.name,
        version: pack.version,
        source: pack.source,
        hash: InstructionPack.hash(pack),
        status: "ready"
      }
    else
      %{
        pack: pack,
        name: pack.name,
        version: pack.version,
        source: pack.source,
        hash: InstructionPack.hash(pack),
        status: "setup_required",
        reason: "Select and install a local Matt Pocock skill before use."
      }
    end
  end

  defp resolve_pack(pack, _config, _context) do
    %{
      pack: pack,
      name: pack.name,
      version: pack.version,
      source: pack.source,
      hash: InstructionPack.hash(pack),
      status: "ready"
    }
  end

  defp compound(name, skill, fragment) do
    %InstructionPack{
      name: name,
      version: 1,
      source: "#{@compound_source}##{skill}",
      fragment: fragment,
      required_capabilities: ["read"],
      expected_artifacts: []
    }
  end

  defp q(value), do: SQLite.quote(value)
end
