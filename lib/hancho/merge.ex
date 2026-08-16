defmodule Hancho.Merge do
  @moduledoc "Applies target, CI, review, authority, and stop guards before one GitHub merge effect."

  alias Hancho.{
    Artifacts,
    Error,
    Git,
    GitHubCLI,
    Journal,
    JSON,
    Publication,
    PullRequest,
    Repository,
    SQLite,
    Store
  }

  @spec merge(Repository.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def merge(repository, run_id, pull_request, options \\ []) do
    remote = Keyword.get(options, :remote, "origin")

    with {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         :ok <- candidate_state(work_order),
         {:ok, candidate} <- Publication.candidate(repository, run_id),
         :ok <- no_uncertain_effects(repository, run_id),
         {:ok, target_commit} <- target_commit(repository, remote, work_order["target_branch"]),
         :ok <- target_fresh(work_order, target_commit, options),
         {:ok, ci} <- PullRequest.observe_ci(repository, run_id, pull_request),
         :ok <- ci_passed(ci),
         {:ok, review} <- PullRequest.observe_review(repository, run_id, pull_request),
         :ok <- review_passed(review, options),
         :ok <- head_matches(review, candidate),
         {:ok, authority} <- merge_authority(repository, run_id, candidate, pull_request, options),
         target <-
           JSON.encode!(%{
             pull_request: pull_request,
             candidate: candidate,
             target_branch: work_order["target_branch"],
             target_commit: target_commit
           }),
         {:ok, effect} <-
           Journal.effect_intent(
             repository,
             run_id,
             "github_merge",
             target,
             "github-merge:#{pull_request}:#{candidate}"
           ),
         {:ok, effect} <- Journal.prepare_effect_retry(repository, effect),
         {:ok, effect, observation} <- perform(repository, effect, pull_request, candidate),
         {:ok, receipt} <-
           write_receipt(
             repository,
             run_id,
             work_order,
             candidate,
             target_commit,
             authority,
             ci,
             review,
             effect,
             observation
           ) do
      {:ok, %{effect: effect, observation: observation, receipt: receipt}}
    end
  end

  defp perform(_repository, %{"status" => "confirmed"} = effect, _pull_request, candidate) do
    observation = JSON.decode!(effect["observation_json"] || "{}")

    if observation["headRefOid"] in [nil, candidate] do
      {:ok, effect, observation}
    else
      {:error,
       error(:merge_head_mismatch, "Observed merge does not contain the exact candidate.")}
    end
  end

  defp perform(repository, %{"status" => "intent"} = effect, pull_request, candidate) do
    case GitHubCLI.command(repository, [
           "pr",
           "merge",
           pull_request,
           "--merge",
           "--match-head-commit",
           candidate
         ]) do
      {:ok, output} ->
        observe_merge(repository, effect, pull_request, candidate, output)

      {:error, failure} ->
        uncertain(repository, effect, failure.message)
    end
  end

  defp perform(_repository, effect, _pull_request, _candidate) do
    {:error,
     error(
       :merge_reconciliation_required,
       "Merge effect '#{effect["id"]}' is '#{effect["status"]}'. Reconcile before retry."
     )}
  end

  defp observe_merge(repository, effect, pull_request, candidate, output) do
    case GitHubCLI.command(repository, [
           "pr",
           "view",
           pull_request,
           "--json",
           "state,mergeCommit,headRefOid,baseRefName,url"
         ]) do
      {:ok, json} ->
        observation = JSON.decode!(json) |> Map.put("command_output", output)

        if observation["state"] == "MERGED" and observation["headRefOid"] == candidate and
             is_binary(get_in(observation, ["mergeCommit", "oid"])) do
          with {:ok, confirmed} <-
                 Journal.observe_effect(repository, effect["id"], "confirmed", observation) do
            {:ok, confirmed, observation}
          end
        else
          uncertain(repository, effect, "GitHub did not confirm the exact merged candidate.")
        end

      {:error, failure} ->
        uncertain(repository, effect, failure.message)
    end
  rescue
    _ -> uncertain(repository, effect, "GitHub returned invalid merge observation JSON.")
  end

  defp uncertain(repository, effect, message) do
    with {:ok, _uncertain} <-
           Journal.observe_effect(repository, effect["id"], "uncertain", %{error: message}) do
      {:error,
       error(
         :merge_uncertain,
         "Merge state is uncertain. Run 'hancho reconcile #{effect["run_id"]}'."
       )}
    end
  end

  defp target_commit(repository, remote, branch) do
    with {:ok, output} <-
           Git.command(repository.root, ["ls-remote", remote, "refs/heads/#{branch}"]),
         [commit | _] <- String.split(output) do
      {:ok, commit}
    else
      _ ->
        {:error, error(:target_not_observed, "Cannot observe remote target branch '#{branch}'.")}
    end
  end

  defp target_fresh(work_order, actual, options) do
    cond do
      actual == work_order["baseline_commit"] ->
        :ok

      Keyword.get(options, :revalidated_target) == actual ->
        :ok

      true ->
        {:error,
         error(
           :target_changed,
           "Target changed from '#{work_order["baseline_commit"]}' to '#{actual}'. Validate the candidate again or supply the exact revalidated target."
         )}
    end
  end

  defp no_uncertain_effects(repository, run_id) do
    with {:ok, effects} <- Journal.uncertain_effects(repository, run_id) do
      if effects == [],
        do: :ok,
        else:
          {:error,
           error(:uncertain_effects_block_merge, "Reconcile uncertain effects before merge.")}
    end
  end

  defp merge_authority(repository, run_id, candidate, pull_request, options) do
    if Keyword.get(options, :require_authority, true) do
      with {:ok, rows} <-
             SQLite.query(
               Store.path(repository),
               "SELECT * FROM decisions WHERE run_id = #{SQLite.quote(run_id)} AND kind = 'merge_authority' ORDER BY requested_at DESC;"
             ) do
        case Enum.find(rows, &approved_for?(&1, candidate, pull_request)) do
          nil ->
            unless Enum.any?(rows, &(&1["status"] == "pending")) do
              Journal.request_decision(repository, run_id, "merge_authority", %{
                candidate_commit: candidate,
                pull_request: pull_request
              })
            end

            {:error,
             error(:merge_authority_required, "An approved merge_authority decision is required.")}

          decision ->
            {:ok, decision}
        end
      end
    else
      {:ok,
       %{"actor" => "policy", "reason" => "Policy does not require separate merge authority."}}
    end
  end

  defp approved_for?(decision, candidate, pull_request) do
    request = JSON.decode!(decision["request_json"] || "{}")

    decision["status"] == "approved" and request["candidate_commit"] == candidate and
      to_string(request["pull_request"]) == to_string(pull_request)
  rescue
    _ -> false
  end

  defp ci_passed(%{passing: true}), do: :ok

  defp ci_passed(_ci),
    do: {:error, error(:ci_not_passing, "Required GitHub CI checks are not passing.")}

  defp review_passed(review, options) do
    if Keyword.get(options, :require_review, true) and review["reviewDecision"] != "APPROVED",
      do: {:error, error(:review_not_approved, "GitHub review is not approved.")},
      else: :ok
  end

  defp head_matches(review, candidate) do
    if review["headRefOid"] == candidate,
      do: :ok,
      else:
        {:error,
         error(:pull_request_head_mismatch, "Pull request head is not the exact candidate.")}
  end

  defp candidate_state(work_order) do
    if work_order["workflow_name"] == "build" and work_order["state"] == "candidate_ready",
      do: :ok,
      else: {:error, error(:candidate_not_ready, "Build candidate is not ready for merge.")}
  end

  defp write_receipt(
         repository,
         run_id,
         work_order,
         candidate,
         target,
         authority,
         ci,
         review,
         effect,
         observation
       ) do
    Artifacts.write(
      repository,
      run_id,
      "receipt",
      "merge.json",
      JSON.encode!(%{
        schema_version: 1,
        run_id: run_id,
        candidate_commit: candidate,
        target_branch: work_order["target_branch"],
        validated_target_commit: target,
        merged_commit: get_in(observation, ["mergeCommit", "oid"]),
        authority: Map.take(authority, ["id", "actor", "reason"]),
        ci: ci,
        review: review,
        effect_id: effect["id"]
      }),
      media_type: "application/json",
      retention: "durable"
    )
  end

  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
