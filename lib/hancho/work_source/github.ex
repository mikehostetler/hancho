defmodule Hancho.WorkSource.GitHub do
  @moduledoc "GitHub commitment-ledger operations through the `gh` CLI."

  alias Hancho.{Error, GitHubCLI, Journal, JSON, Repository}

  @material_events ~w(scope_change owner_decision blocker delivery_result)

  @spec view_issue(Repository.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def view_issue(repository, reference) do
    with {:ok, output} <-
           command(repository, [
             "issue",
             "view",
             reference,
             "--json",
             "number,title,state,url,body,labels"
           ]) do
      try do
        {:ok, JSON.decode!(output)}
      rescue
        _ ->
          {:error,
           %Error{
             code: :github_invalid_json,
             exit_status: 65,
             message: "GitHub returned invalid issue JSON."
           }}
      end
    end
  end

  @spec post_material_event(Repository.t(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def post_material_event(repository, run_id, reference, kind, body)
      when kind in @material_events do
    idempotency_key =
      "github-issue:#{reference}:#{kind}:#{:crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}"

    with {:ok, effect} <-
           Journal.effect_intent(
             repository,
             run_id,
             "github_issue_#{kind}",
             reference,
             idempotency_key
           ),
         {:ok, effect} <- Journal.prepare_effect_retry(repository, effect) do
      case effect["status"] do
        "confirmed" ->
          {:ok, effect}

        "intent" ->
          case command(repository, ["issue", "comment", reference, "--body", body]) do
            {:ok, output} ->
              Journal.observe_effect(repository, effect["id"], "confirmed", %{output: output})

            {:error, error} ->
              Journal.observe_effect(repository, effect["id"], "uncertain", %{
                error: error.message
              })
          end

        status ->
          {:error,
           %Error{
             code: :effect_not_retryable,
             exit_status: 75,
             message: "GitHub effect '#{effect["id"]}' is '#{status}' and needs reconciliation."
           }}
      end
    end
  end

  def post_material_event(_repository, _run_id, _reference, kind, _body) do
    {:error,
     %Error{
       code: :routine_github_event_rejected,
       exit_status: 65,
       message: "Event '#{kind}' is routine progress and must not be posted to GitHub."
     }}
  end

  @spec link_beadwork(Repository.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def link_beadwork(repository, run_id, issue, beadwork_id) do
    post_material_event(
      repository,
      run_id,
      issue,
      "owner_decision",
      "Hancho-Beadwork-Root: #{beadwork_id}"
    )
  end

  @spec close_issue(Repository.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def close_issue(repository, run_id, reference, final_note) do
    idempotency_key =
      "github-issue-close:#{reference}:#{:crypto.hash(:sha256, final_note) |> Base.encode16(case: :lower)}"

    with {:ok, effect} <-
           Journal.effect_intent(
             repository,
             run_id,
             "github_issue_close",
             reference,
             idempotency_key
           ),
         {:ok, effect} <- Journal.prepare_effect_retry(repository, effect) do
      case effect["status"] do
        "confirmed" ->
          {:ok, effect}

        "intent" ->
          case GitHubCLI.command(repository, [
                 "issue",
                 "close",
                 reference,
                 "--comment",
                 final_note
               ]) do
            {:ok, output} ->
              Journal.observe_effect(repository, effect["id"], "confirmed", %{output: output})

            {:error, error} ->
              Journal.observe_effect(repository, effect["id"], "uncertain", %{
                error: error.message
              })
          end

        status ->
          {:error,
           %Error{
             code: :effect_not_retryable,
             exit_status: 75,
             message:
               "GitHub close effect '#{effect["id"]}' is '#{status}' and needs reconciliation."
           }}
      end
    end
  end

  defp command(repository, args) do
    GitHubCLI.command(repository, args)
  end
end
