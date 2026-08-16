defmodule Hancho.PullRequest do
  @moduledoc "Creates one idempotent pull request and records GitHub evidence as observations."

  alias Hancho.{Error, GitHubCLI, Journal, JSON, Publication, Repository, WorkRecords}

  @spec open(Repository.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def open(repository, run_id, options \\ []) do
    with {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         {:ok, candidate} <- Publication.candidate(repository, run_id),
         branch <- Keyword.get(options, :branch, Publication.branch_name(run_id)),
         base <- Keyword.get(options, :base, work_order["target_branch"] || repository.branch),
         {:ok, references} <- WorkRecords.list(repository, run_id),
         target <- JSON.encode!(%{branch: branch, base: base, candidate: candidate}),
         {:ok, effect} <-
           Journal.effect_intent(
             repository,
             run_id,
             "github_pull_request",
             target,
             "github-pr:#{run_id}:#{branch}:#{base}"
           ),
         {:ok, effect} <- Journal.prepare_effect_retry(repository, effect),
         {:ok, effect, pull_request} <-
           perform(repository, effect, work_order, candidate, branch, base, references, options) do
      {:ok, %{effect: effect, pull_request: pull_request}}
    end
  end

  @spec observe_ci(Repository.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def observe_ci(repository, run_id, reference) do
    with {:ok, output} <-
           GitHubCLI.command(repository, [
             "pr",
             "checks",
             reference,
             "--json",
             "name,state,link,bucket"
           ]),
         checks <- decode(output),
         {:ok, _event} <-
           Journal.record_event(repository, run_id, "ci_observed",
             actor: "github",
             reason: "GitHub CI state was observed",
             payload: %{pull_request: reference, checks: checks}
           ) do
      {:ok, %{checks: checks, passing: Enum.all?(checks, &passing_check?/1)}}
    end
  end

  @spec observe_review(Repository.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def observe_review(repository, run_id, reference) do
    with {:ok, output} <-
           GitHubCLI.command(repository, [
             "pr",
             "view",
             reference,
             "--json",
             "reviewDecision,reviews,headRefOid,baseRefName,state"
           ]),
         review <- decode(output),
         {:ok, _event} <-
           Journal.record_event(repository, run_id, "review_observed",
             actor: "github",
             reason: "GitHub review state was observed",
             payload: review
           ) do
      {:ok, review}
    end
  end

  defp perform(
         repository,
         %{"status" => "confirmed"} = effect,
         _work_order,
         candidate,
         branch,
         _base,
         _references,
         _options
       ) do
    with {:ok, pull_request} <- find(repository, branch),
         :ok <- exact_head(pull_request, candidate) do
      {:ok, effect, pull_request}
    end
  end

  defp perform(
         repository,
         %{"status" => "intent"} = effect,
         work_order,
         candidate,
         branch,
         base,
         references,
         options
       ) do
    case find(repository, branch) do
      {:ok, pull_request} ->
        confirm(repository, effect, pull_request, candidate)

      {:error, %{code: :pull_request_not_found}} ->
        create(repository, effect, work_order, candidate, branch, base, references, options)

      {:error, failure} ->
        uncertain(repository, effect, failure)
    end
  end

  defp perform(
         _repository,
         effect,
         _work_order,
         _candidate,
         _branch,
         _base,
         _references,
         _options
       ) do
    {:error,
     error(
       :pull_request_reconciliation_required,
       "Pull request effect '#{effect["id"]}' is '#{effect["status"]}'. Reconcile before retry."
     )}
  end

  defp create(repository, effect, work_order, candidate, branch, base, references, options) do
    title = Keyword.get(options, :title, "Hancho: #{work_order["work_ref"]}")
    body = body(work_order, candidate, references)

    case GitHubCLI.command(repository, [
           "pr",
           "create",
           "--head",
           branch,
           "--base",
           base,
           "--title",
           title,
           "--body",
           body
         ]) do
      {:ok, _output} ->
        case find(repository, branch) do
          {:ok, pull_request} -> confirm(repository, effect, pull_request, candidate)
          {:error, failure} -> uncertain(repository, effect, failure)
        end

      {:error, failure} ->
        uncertain(repository, effect, failure)
    end
  end

  defp confirm(repository, effect, pull_request, candidate) do
    case exact_head(pull_request, candidate) do
      :ok ->
        with {:ok, observed} <-
               Journal.observe_effect(repository, effect["id"], "confirmed", pull_request) do
          {:ok, observed, pull_request}
        end

      {:error, failure} ->
        uncertain(repository, effect, failure)
    end
  end

  defp uncertain(repository, effect, failure) do
    with {:ok, uncertain} <-
           Journal.observe_effect(repository, effect["id"], "uncertain", %{
             error: Exception.message(failure)
           }) do
      {:error,
       error(
         :pull_request_uncertain,
         "Pull request effect '#{uncertain["id"]}' is uncertain and needs reconciliation."
       )}
    end
  end

  defp find(repository, branch) do
    with {:ok, output} <-
           GitHubCLI.command(repository, [
             "pr",
             "list",
             "--head",
             branch,
             "--state",
             "all",
             "--limit",
             "1",
             "--json",
             "number,url,headRefOid,baseRefName,state"
           ]),
         data when is_list(data) <- decode(output) do
      case data do
        [pull_request | _] -> {:ok, pull_request}
        [] -> {:error, error(:pull_request_not_found, "No pull request exists for '#{branch}'.")}
      end
    else
      {:error, failure} -> {:error, failure}
      _ -> {:error, error(:github_invalid_json, "GitHub returned invalid pull request data.")}
    end
  end

  defp exact_head(pull_request, candidate) do
    if pull_request["headRefOid"] == candidate,
      do: :ok,
      else:
        {:error,
         error(
           :pull_request_head_mismatch,
           "Pull request does not name candidate '#{candidate}'."
         )}
  end

  defp body(work_order, candidate, references) do
    links = Enum.map_join(references, "\n", &"- #{&1["kind"]}: #{&1["reference"]}")

    """
    Hancho work order: #{work_order["id"]}
    Candidate commit: #{candidate}
    Target branch: #{work_order["target_branch"]}

    Work records:
    #{if links == "", do: "- none", else: links}

    Evidence: `.hancho` candidate and publication receipts for work order #{work_order["id"]}.
    """
  end

  defp passing_check?(check),
    do:
      check["bucket"] in ["pass", "skipping"] or
        check["state"] in ["SUCCESS", "NEUTRAL", "SKIPPED"]

  defp decode(""), do: []
  defp decode(output), do: JSON.decode!(output)
  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
