defmodule Hancho.ReconcilerTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.{Config, Git, Journal, JSON, Reconciler, Repository}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    {:ok, work_order} = Journal.create_work_order(repository, config, definition, "effect-work")
    %{root: root, repository: repository, run_id: work_order["id"]}
  end

  test "confirms a local Git ref without repeating the effect", context do
    {:ok, commit} = Git.command(context.root, ["rev-parse", "HEAD"])
    {:ok, _} = Git.command(context.root, ["update-ref", "refs/hancho/test", commit])
    target = JSON.encode!(%{ref: "refs/hancho/test", commit: commit})

    {:ok, effect} =
      Journal.effect_intent(
        context.repository,
        context.run_id,
        "git_local_ref",
        target,
        "local-ref:one"
      )

    assert :ok = Journal.mark_incomplete_effects_uncertain(context.repository)
    assert {:ok, result} = Reconciler.reconcile_run(context.repository, context.run_id)
    assert result.unresolved == 0
    assert [%{"id" => id, "status" => "confirmed"}] = result.effects
    assert id == effect["id"]
  end

  test "keeps an unknown effect uncertain with a useful observation", context do
    {:ok, _} =
      Journal.effect_intent(
        context.repository,
        context.run_id,
        "unknown_effect",
        "target",
        "unknown:one"
      )

    assert :ok = Journal.mark_incomplete_effects_uncertain(context.repository)
    assert {:ok, %{unresolved: 1}} = Reconciler.reconcile_run(context.repository, context.run_id)
  end

  test "supports an injected external-state checker", context do
    {:ok, _} =
      Journal.effect_intent(
        context.repository,
        context.run_id,
        "fixture",
        "target",
        "fixture:one"
      )

    assert :ok = Journal.mark_incomplete_effects_uncertain(context.repository)
    checker = fn _repository, _effect -> {:ok, "absent", %{checked: true}} end

    assert {:ok, %{effects: [%{"status" => "absent"}]}} =
             Reconciler.reconcile_run(context.repository, context.run_id, checker: checker)
  end

  test "an observed absence permits one explicit retry with the same idempotency key", context do
    {:ok, effect} =
      Journal.effect_intent(
        context.repository,
        context.run_id,
        "fixture",
        "target",
        "fixture:retry"
      )

    assert :ok = Journal.mark_incomplete_effects_uncertain(context.repository)
    checker = fn _repository, _effect -> {:ok, "absent", %{checked: true}} end

    assert {:ok, %{unresolved: 0}} =
             Reconciler.reconcile_run(context.repository, context.run_id, checker: checker)

    assert {:ok, [absent]} =
             Hancho.SQLite.query(
               Hancho.Store.path(context.repository),
               "SELECT * FROM effects WHERE id = #{Hancho.SQLite.quote(effect["id"])};"
             )

    assert absent["status"] == "absent"
    assert {:ok, retried} = Journal.prepare_effect_retry(context.repository, absent)
    assert retried["status"] == "intent"
    assert retried["idempotency_key"] == "fixture:retry"

    assert {:ok, events} = Journal.events(context.repository, context.run_id)
    assert Enum.any?(events, &(&1["event"] == "effect_retry_requested"))
  end
end
