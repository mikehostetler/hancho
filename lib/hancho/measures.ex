defmodule Hancho.Measures do
  @moduledoc "Calculates flow and quality measures only from durable journal facts."

  alias Hancho.{Repository, SQLite, Store}

  @definitions %{
    oldest_committed_age_seconds: %{
      source: "work_orders.created_at where status is ready or active",
      calculation: "Current UTC time minus the earliest eligible created_at."
    },
    active_wip: %{
      source: "work_orders.status",
      calculation: "Count of work orders with status active."
    },
    start_to_merge_seconds: %{
      source: "events.event=start and effects.kind=github_merge,status=confirmed",
      calculation:
        "For each merged run, confirmed merge observed_at minus first start occurred_at."
    },
    blocked_time_seconds: %{
      source: "events.event=andon and the next resume_requested event",
      calculation: "Sum of each Andon-to-resume interval. Open stops run to report time."
    },
    rework_count: %{
      source: "events.event",
      calculation: "Count checks_failed, review_rework, and repair_ready events."
    },
    review_wait_seconds: %{
      source: "events.event=checks_passed and review_accepted",
      calculation: "For each run, review acceptance time minus checks-passed time."
    },
    failed_delivery_count: %{
      source: "delivery_requests.status",
      calculation: "Count delivery requests in uncertain status."
    },
    andon_causes: %{
      source: "events.event=andon, reason",
      calculation: "Frequency of recorded Andon reasons."
    }
  }

  @spec report(Repository.t(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def report(repository, now \\ DateTime.utc_now()) do
    with {:ok, work_orders} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM work_orders ORDER BY created_at, id;"
           ),
         {:ok, events} <-
           SQLite.query(Store.path(repository), "SELECT * FROM events ORDER BY run_id, seq;"),
         {:ok, merges} <-
           SQLite.query(
             Store.path(repository),
             "SELECT * FROM effects WHERE kind = 'github_merge' AND status = 'confirmed' ORDER BY observed_at, id;"
           ),
         {:ok, failed_deliveries} <-
           SQLite.scalar(
             Store.path(repository),
             "SELECT COUNT(*) FROM delivery_requests WHERE status = 'uncertain';"
           ) do
      {:ok,
       %{
         generated_at: DateTime.to_iso8601(now),
         policy:
           "Use measures for workflow improvement. Do not rank people or reward code volume.",
         definitions: @definitions,
         values: %{
           oldest_committed_age_seconds: oldest_age(work_orders, now),
           active_wip: Enum.count(work_orders, &(&1["status"] == "active")),
           start_to_merge_seconds: intervals(events, merges, "start"),
           blocked_time_seconds: blocked_time(events, now),
           rework_count:
             Enum.count(
               events,
               &(&1["event"] in ["checks_failed", "review_rework", "repair_ready"])
             ),
           review_wait_seconds:
             paired_event_intervals(events, "checks_passed", "review_accepted"),
           failed_delivery_count: failed_deliveries || 0,
           andon_causes: andon_causes(events)
         }
       }}
    end
  end

  defp oldest_age(work_orders, now) do
    work_orders
    |> Enum.filter(&(&1["status"] in ["ready", "active", "stopped"]))
    |> Enum.map(&seconds_between(&1["created_at"], DateTime.to_iso8601(now)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp intervals(events, effects, start_event) do
    starts =
      events
      |> Enum.filter(&(&1["event"] == start_event))
      |> Map.new(&{&1["run_id"], &1["occurred_at"]})

    Enum.flat_map(effects, fn effect ->
      case starts[effect["run_id"]] do
        nil ->
          []

        started ->
          [%{run_id: effect["run_id"], seconds: seconds_between(started, effect["observed_at"])}]
      end
    end)
  end

  defp blocked_time(events, now) do
    events
    |> Enum.group_by(& &1["run_id"])
    |> Enum.map(fn {run_id, run_events} ->
      seconds =
        run_events
        |> Enum.with_index()
        |> Enum.filter(fn {event, _index} -> event["event"] == "andon" end)
        |> Enum.map(fn {andon, index} ->
          resumed =
            Enum.drop(run_events, index + 1) |> Enum.find(&(&1["event"] == "resume_requested"))

          seconds_between(
            andon["occurred_at"],
            if(resumed, do: resumed["occurred_at"], else: DateTime.to_iso8601(now))
          ) || 0
        end)
        |> Enum.sum()

      %{run_id: run_id, seconds: seconds}
    end)
  end

  defp paired_event_intervals(events, left, right) do
    events
    |> Enum.group_by(& &1["run_id"])
    |> Enum.flat_map(fn {run_id, run_events} ->
      with left_event when is_map(left_event) <- Enum.find(run_events, &(&1["event"] == left)),
           right_event when is_map(right_event) <- Enum.find(run_events, &(&1["event"] == right)) do
        [
          %{
            run_id: run_id,
            seconds: seconds_between(left_event["occurred_at"], right_event["occurred_at"])
          }
        ]
      else
        _ -> []
      end
    end)
  end

  defp andon_causes(events) do
    events
    |> Enum.filter(&(&1["event"] == "andon"))
    |> Enum.frequencies_by(&(&1["reason"] || "unspecified"))
  end

  defp seconds_between(left, right) do
    with {:ok, left_time, _} <- DateTime.from_iso8601(left),
         {:ok, right_time, _} <- DateTime.from_iso8601(right) do
      max(DateTime.diff(right_time, left_time, :second), 0)
    else
      _ -> nil
    end
  end
end
