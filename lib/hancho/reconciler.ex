defmodule Hancho.Reconciler do
  @moduledoc "Observes uncertain external effects before a policy permits retry."

  alias Hancho.{Error, Git, GitHubCLI, Journal, JSON, Repository}

  @spec reconcile_run(Repository.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def reconcile_run(repository, run_id, options \\ []) do
    checker = Keyword.get(options, :checker, &check/2)

    with :ok <- Journal.resolve_uncertain_actions(repository, run_id),
         {:ok, effects} <- Journal.uncertain_effects(repository, run_id) do
      results =
        Enum.map(effects, fn effect ->
          case checker.(repository, effect) do
            {:ok, status, observation}
            when status in ["confirmed", "absent", "failed", "contained", "reversed"] ->
              {:ok, observed} =
                Journal.observe_effect(repository, effect["id"], status, observation)

              Journal.record_event(repository, run_id, "effect_reconciled",
                reason: "External state observed",
                payload: %{effect_id: effect["id"], status: status}
              )

              observed

            {:ambiguous, observation} ->
              {:ok, observed} =
                Journal.observe_effect(repository, effect["id"], "uncertain", observation)

              observed
          end
        end)

      {:ok,
       %{
         run_id: run_id,
         effects: results,
         actions: "interrupted actions marked failed after process absence was observed",
         unresolved: Enum.count(results, &(&1["status"] == "uncertain"))
       }}
    end
  end

  defp check(repository, %{"kind" => "git_local_ref", "target" => target}) do
    with {:ok, data} <- decode_target(target),
         {:ok, actual} <- Git.command(repository.root, ["rev-parse", "--verify", data["ref"]]) do
      if actual == data["commit"],
        do: {:ok, "confirmed", %{actual: actual}},
        else: {:ok, "absent", %{actual: actual}}
    else
      {:error, _} -> {:ok, "absent", %{reason: "ref was not found"}}
    end
  end

  defp check(repository, %{"kind" => "git_push", "target" => target}) do
    with {:ok, data} <- decode_target(target),
         {:ok, output} <- Git.command(repository.root, ["ls-remote", data["remote"], data["ref"]]) do
      actual = output |> String.split() |> List.first()

      if actual == data["commit"],
        do: {:ok, "confirmed", %{actual: actual}},
        else: {:ok, "absent", %{actual: actual}}
    else
      {:error, error} -> {:ambiguous, %{error: Exception.message(error)}}
    end
  end

  defp check(repository, %{"kind" => "github_pull_request", "target" => target}) do
    with {:ok, data} <- decode_target(target),
         {:ok, output} <-
           GitHubCLI.command(repository, [
             "pr",
             "list",
             "--head",
             data["branch"],
             "--state",
             "all",
             "--limit",
             "1",
             "--json",
             "number,url,headRefOid,baseRefName,state"
           ]),
         pull_requests when is_list(pull_requests) <- JSON.decode!(output) do
      expected = data["candidate"]

      case pull_requests do
        [%{"headRefOid" => ^expected} = pull_request | _] ->
          {:ok, "confirmed", pull_request}

        [] ->
          {:ok, "absent", %{branch: data["branch"]}}

        pull_requests ->
          {:ambiguous, %{pull_requests: pull_requests, expected_commit: data["candidate"]}}
      end
    else
      {:error, error} -> {:ambiguous, %{error: Exception.message(error)}}
      _ -> {:ambiguous, %{error: "GitHub returned invalid pull request data."}}
    end
  rescue
    _ -> {:ambiguous, %{error: "GitHub returned invalid pull request JSON."}}
  end

  defp check(repository, %{"kind" => "github_merge", "target" => target}) do
    with {:ok, data} <- decode_target(target),
         {:ok, output} <-
           GitHubCLI.command(repository, [
             "pr",
             "view",
             data["pull_request"],
             "--json",
             "state,mergeCommit,headRefOid,baseRefName,url"
           ]),
         observation when is_map(observation) <- JSON.decode!(output) do
      cond do
        observation["state"] == "MERGED" and
            observation["headRefOid"] == data["candidate"] ->
          {:ok, "confirmed", observation}

        observation["state"] in ["OPEN", "CLOSED"] ->
          {:ok, "absent", observation}

        true ->
          {:ambiguous, observation}
      end
    else
      {:error, error} -> {:ambiguous, %{error: Exception.message(error)}}
      _ -> {:ambiguous, %{error: "GitHub returned invalid merge data."}}
    end
  rescue
    _ -> {:ambiguous, %{error: "GitHub returned invalid merge JSON."}}
  end

  defp check(_repository, effect) do
    {:ambiguous, %{reason: "No reconciler is installed for '#{effect["kind"]}'."}}
  end

  defp decode_target(target) do
    {:ok, JSON.decode!(target)}
  rescue
    _ ->
      {:error,
       %Error{
         code: :invalid_effect_target,
         exit_status: 65,
         message: "Effect target is not valid JSON."
       }}
  end
end
