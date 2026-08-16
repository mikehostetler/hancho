defmodule Hancho.Publication do
  @moduledoc "Publishes an exact accepted candidate under a Hancho-owned branch without force push."

  alias Hancho.{Artifacts, Error, Git, Journal, JSON, Repository}

  @spec publish(Repository.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def publish(repository, run_id, options \\ []) do
    remote = Keyword.get(options, :remote, "origin")

    with {:ok, work_order} <- Journal.get_work_order(repository, run_id),
         :ok <- candidate_ready(work_order),
         {:ok, candidate} <- candidate(repository, run_id),
         branch <- Keyword.get(options, :branch, branch_name(run_id)),
         {:ok, remote_url} <- Git.command(repository.root, ["remote", "get-url", remote]),
         target <-
           JSON.encode!(%{
             remote: remote,
             remote_url: remote_url,
             ref: "refs/heads/#{branch}",
             commit: candidate
           }),
         {:ok, effect} <-
           Journal.effect_intent(
             repository,
             run_id,
             "git_push",
             target,
             "git-push:#{remote}:#{branch}:#{candidate}"
           ),
         {:ok, effect} <- Journal.prepare_effect_retry(repository, effect),
         {:ok, effect} <- perform(repository, effect, remote, branch, candidate),
         {:ok, receipt} <-
           write_receipt(repository, run_id, remote, remote_url, branch, candidate, effect) do
      {:ok,
       %{
         effect: effect,
         receipt: receipt,
         remote: remote,
         remote_url: remote_url,
         branch: branch,
         candidate_commit: candidate
       }}
    end
  end

  @spec candidate(Repository.t(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def candidate(repository, run_id) do
    case Git.command(repository.root, [
           "rev-parse",
           "--verify",
           "refs/hancho/candidates/#{run_id}^{commit}"
         ]) do
      {:ok, commit} ->
        {:ok, commit}

      {:error, _error} ->
        {:error, error(:candidate_ref_missing, "No retained candidate exists for '#{run_id}'.")}
    end
  end

  @spec branch_name(String.t()) :: String.t()
  def branch_name(run_id) do
    safe = String.replace(run_id, ~r/[^A-Za-z0-9._-]+/, "-")
    "hancho/#{safe}"
  end

  defp perform(_repository, %{"status" => "confirmed"} = effect, _remote, _branch, _candidate),
    do: {:ok, effect}

  defp perform(repository, %{"status" => "intent"} = effect, remote, branch, candidate) do
    case Git.command(repository.root, ["push", remote, "#{candidate}:refs/heads/#{branch}"]) do
      {:ok, output} ->
        case observe_remote(repository, remote, branch, candidate) do
          {:ok, observation} ->
            Journal.observe_effect(
              repository,
              effect["id"],
              "confirmed",
              Map.put(observation, :push_output, output)
            )

          {:error, observation} ->
            Journal.observe_effect(repository, effect["id"], "uncertain", observation)
        end

      {:error, failure} ->
        Journal.observe_effect(repository, effect["id"], "uncertain", %{error: failure.message})
    end
  end

  defp perform(_repository, effect, _remote, _branch, _candidate) do
    {:error,
     error(
       :publication_reconciliation_required,
       "Publication effect '#{effect["id"]}' is '#{effect["status"]}'. Reconcile before retry."
     )}
  end

  defp observe_remote(repository, remote, branch, candidate) do
    with {:ok, output} <-
           Git.command(repository.root, ["ls-remote", remote, "refs/heads/#{branch}"]) do
      actual = output |> String.split() |> List.first()

      if actual == candidate,
        do: {:ok, %{remote_commit: actual, ref: "refs/heads/#{branch}"}},
        else: {:error, %{expected: candidate, actual: actual, ref: "refs/heads/#{branch}"}}
    else
      {:error, failure} -> {:error, %{error: failure.message}}
    end
  end

  defp write_receipt(repository, run_id, remote, remote_url, branch, candidate, effect) do
    Artifacts.write(
      repository,
      run_id,
      "receipt",
      "publication.json",
      JSON.encode!(%{
        schema_version: 1,
        run_id: run_id,
        local_candidate_commit: candidate,
        remote_candidate_commit: candidate,
        remote: remote,
        remote_url: remote_url,
        remote_ref: "refs/heads/#{branch}",
        effect_id: effect["id"]
      }),
      media_type: "application/json",
      retention: "durable"
    )
  end

  defp candidate_ready(work_order) do
    if work_order["workflow_name"] == "build" and work_order["state"] == "candidate_ready" do
      :ok
    else
      {:error,
       error(
         :candidate_not_ready,
         "Work order '#{work_order["id"]}' has no accepted Build.V1 candidate."
       )}
    end
  end

  defp error(code, message), do: %Error{code: code, exit_status: 75, message: message}
end
