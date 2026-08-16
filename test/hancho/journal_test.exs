defmodule Hancho.JournalTest do
  use Hancho.RepositoryCase, async: true

  alias Hancho.Workflow.Event
  alias Hancho.{Config, Journal, Repository, SQLite, Store}

  setup do
    root = temporary_git_repository!()
    {:ok, repository} = Repository.discover(root)
    {:ok, _} = Repository.init(repository)
    {:ok, repository} = Repository.discover(root)
    {:ok, config} = Config.load(repository)
    definition = Hancho.Workflows.WalkingSkeleton.V1.definition()
    %{repository: repository, config: config, definition: definition}
  end

  test "creates, transitions, lists, and replays one pinned work order", context do
    assert {:ok, work_order} =
             Journal.create_work_order(
               context.repository,
               context.config,
               context.definition,
               "work-1"
             )

    assert work_order["state"] == "released"
    assert work_order["workflow_version"] == 1

    event = %Event{
      name: "start",
      expected_state: "released",
      actor: "owner",
      reason: "Capacity is ready"
    }

    assert {:ok, transition} =
             Journal.transition(context.repository, work_order["id"], context.definition, event)

    assert transition.state == "operating"

    assert {:ok, final} =
             Journal.transition(
               context.repository,
               work_order["id"],
               context.definition,
               "harness_succeeded"
             )

    assert final.work_order["state"] == "complete"
    assert final.work_order["status"] == "complete"
    assert :ok = Journal.verify_replay(context.repository, work_order["id"], context.definition)

    assert {:ok, events} = Journal.events(context.repository, work_order["id"])
    assert Enum.map(events, & &1["seq"]) == [1, 2, 3]
    assert Enum.map(events, & &1["event"]) == ["created", "start", "harness_succeeded"]
  end

  test "does not store an invalid or stale transition", context do
    {:ok, work_order} =
      Journal.create_work_order(context.repository, context.config, context.definition, "work-2")

    assert {:error, %{code: :invalid_event}} =
             Journal.transition(
               context.repository,
               work_order["id"],
               context.definition,
               "harness_succeeded"
             )

    stale = %Event{name: "start", expected_state: "operating"}

    assert {:error, %{code: :stale_event}} =
             Journal.transition(context.repository, work_order["id"], context.definition, stale)

    assert {:ok, [_created]} = Journal.events(context.repository, work_order["id"])
  end

  test "does not use a different workflow version", context do
    {:ok, work_order} =
      Journal.create_work_order(context.repository, context.config, context.definition, "work-3")

    build = Hancho.Workflows.Build.V1.definition()

    assert {:error, %{code: :workflow_pin_mismatch}} =
             Journal.transition(context.repository, work_order["id"], build, "start")
  end

  test "enforces action order and stable idempotency", context do
    {:ok, work_order} =
      Journal.create_work_order(context.repository, context.config, context.definition, "work-4")

    assert {:ok, requested} =
             Journal.request_action(
               context.repository,
               work_order["id"],
               "operate",
               "run_harness",
               "run:operate:1"
             )

    assert {:ok, same} =
             Journal.request_action(
               context.repository,
               work_order["id"],
               "operate",
               "run_harness",
               "run:operate:1"
             )

    assert same["id"] == requested["id"]

    assert {:error, %{code: :action_state_conflict}} =
             Journal.finish_action(context.repository, requested["id"], "completed", %{})

    assert {:ok, started} = Journal.start_action(context.repository, requested["id"])
    assert started["status"] == "started"

    assert {:ok, completed} =
             Journal.finish_action(context.repository, requested["id"], "completed", %{ok: true})

    assert completed["status"] == "completed"
  end

  test "marks an interrupted effect uncertain and reconciles it", context do
    {:ok, work_order} =
      Journal.create_work_order(context.repository, context.config, context.definition, "work-5")

    assert {:ok, effect} =
             Journal.effect_intent(
               context.repository,
               work_order["id"],
               "git_push",
               "origin/main",
               "push:one"
             )

    assert effect["status"] == "intent"
    assert :ok = Journal.mark_incomplete_effects_uncertain(context.repository)
    assert {:ok, [uncertain]} = Journal.uncertain_effects(context.repository, work_order["id"])
    assert uncertain["id"] == effect["id"]

    assert {:ok, observed} =
             Journal.observe_effect(context.repository, effect["id"], "absent", %{
               remote_has_commit: false
             })

    assert observed["status"] == "absent"
    assert {:ok, []} = Journal.uncertain_effects(context.repository, work_order["id"])
  end

  test "records one durable answer and rejects a conflicting answer", context do
    {:ok, work_order} =
      Journal.create_work_order(context.repository, context.config, context.definition, "work-6")

    {:ok, decision} =
      Journal.request_decision(context.repository, work_order["id"], "migration", %{
        path: "one.exs"
      })

    assert {:ok, approved} =
             Journal.decide(context.repository, decision["id"], "approved", "owner", "Reviewed")

    assert approved["status"] == "approved"

    assert {:ok, _same} =
             Journal.decide(context.repository, decision["id"], "approved", "owner", "Reviewed")

    assert {:error, %{code: :decision_conflict}} =
             Journal.decide(
               context.repository,
               decision["id"],
               "rejected",
               "owner",
               "Changed mind"
             )

    assert {:ok, []} = Journal.open_decisions(context.repository)
  end

  test "current state and event append occur together", context do
    {:ok, work_order} =
      Journal.create_work_order(context.repository, context.config, context.definition, "work-7")

    {:ok, _} =
      Journal.transition(context.repository, work_order["id"], context.definition, "start")

    db = Store.path(context.repository)

    assert {:ok, state} =
             SQLite.scalar(
               db,
               "SELECT state FROM work_orders WHERE id = #{SQLite.quote(work_order["id"])};"
             )

    assert {:ok, event_state} =
             SQLite.scalar(
               db,
               "SELECT result_state FROM events WHERE run_id = #{SQLite.quote(work_order["id"])} ORDER BY seq DESC LIMIT 1;"
             )

    assert state == event_state
  end
end
